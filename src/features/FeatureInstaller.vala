namespace Ilia {
    /**
     * Lists the feature packages of a session through PackageKit and installs one at a time: a trial
     * first, then a question, then the change, then a fresh listing. The page that shows the packages
     * follows it through its signals.
     */
    public class FeatureInstaller : GLib.Object {
        public enum Activity {
            IDLE,
            TRIAL,       // asking PackageKit what the change would do
            PROMPT,      // waiting for the user to confirm the change
            TRANSACTION, // changing the system
            REFRESHING   // the change has ended; the packages are listed afresh
        }

        // The packages were listed (afresh); empty when PackageKit could not list them
        public signal void catalogue_changed();
        // The activity, its package, the question or the progress changed
        public signal void state_changed();

        public Activity activity { get; private set; default = Activity.IDLE; }
        // The package acted upon, while there is an activity
        public string ? target_name { get; private set; default = null; }
        // The question, while the activity is PROMPT
        public string ? prompt_text { get; private set; default = null; }
        public int percentage { get; private set; default = -1; }
        // The package whose last change failed, and why, until the next change begins
        public string ? failed_name { get; private set; default = null; }
        public string ? failed_details { get; private set; default = null; }

        private FeatureSession session;
        private SessionContoller session_controller;
        private bool is_wayland;
        private Pk.Client ? client = null;
        private uint catalogue_generation = 0;
        private Gee.HashMap<string, FeaturePackage> packages = new Gee.HashMap<string, FeaturePackage>();
        private FeaturePackage[] package_list = {};

        private string ? target_id = null;
        private bool allow_cancel = false;
        private bool cancel_requested = false;
        private GLib.Cancellable ? cancellable = null;
        private bool waiting_for_auth = false;
        private bool input_shared = false;

        public FeatureInstaller (FeatureSession session, SessionContoller session_controller, bool is_wayland) {
            this.session = session;
            this.session_controller = session_controller;
            this.is_wayland = is_wayland;
        }

        public FeaturePackage[] get_packages() {
            return package_list;
        }

        public FeaturePackage ? get_package(string name) {
            return packages.get(name);
        }

        private Pk.Client get_client() {
            if (client == null) {
                client = new Pk.Client();
                // Installs may ask the user for authorisation
                client.set_interactive(true);
            }
            return client;
        }

        public void refresh_catalogue() {
            uint generation = ++catalogue_generation;
            var filters = Pk.Bitfield.from_enums(Pk.Filter.ARCH, Pk.Filter.NEWEST, -1);

            get_client().get_packages_async.begin(filters, null, (progress, type) => {}, (obj, res) => {
                FeatureCatalogue ? catalogue = null;
                try {
                    var results = client.get_packages_async.end(res);
                    if (results.get_exit_code() == Pk.Exit.SUCCESS) {
                        catalogue = new FeatureCatalogue(session);
                        foreach (var package in results.get_package_array()) {
                            bool installed = package.get_info() == Pk.Info.INSTALLED || FeatureCatalogue.is_installed_id(package.get_id());
                            catalogue.add(package.get_id(), package.get_summary() ?? "", installed);
                        }
                    } else {
                        stderr.printf("Unable to list packages: %s\n", error_details(results));
                    }
                } catch (GLib.Error e) {
                    stderr.printf("Unable to list packages: %s\n", e.message);
                }
                if (generation != catalogue_generation)
                    return;

                packages.clear();
                package_list = catalogue != null ? catalogue.get_packages() : new FeaturePackage[0];
                foreach (var package in package_list)
                    packages.set(package.name, package);
                if (activity == Activity.REFRESHING) {
                    activity = Activity.IDLE;
                    target_name = null;
                }
                catalogue_changed();
                state_changed();
            });
        }

        /**
         * Enter on the row of package name: start the trial of installing it, or confirm the question about it.
         */
        public void activate(string name) {
            var package = packages.get(name);
            if (package == null || package.installed)
                return;

            switch (activity) {
                case Activity.IDLE:
                    target_id = package.available_id;
                    if (target_id == null)
                        return;
                    target_name = package.name;
                    failed_name = null;
                    failed_details = null;
                    begin_activity(Activity.TRIAL);
                    state_changed();
                    run_trial.begin();
                    break;
                case Activity.PROMPT:
                    if (package.name == target_name)
                        run_transaction.begin();
                    break;
                default:
                    break;
            }
        }

        /**
         * Escape: discard the question, or cancel the trial or the change if PackageKit allows it. False
         * when there is nothing to cancel.
         */
        public bool cancel() {
            switch (activity) {
                case Activity.PROMPT:
                    end_activity(Activity.IDLE);
                    return true;
                case Activity.TRIAL:
                case Activity.TRANSACTION:
                    if (allow_cancel && !cancel_requested && cancellable != null) {
                        cancel_requested = true;
                        cancellable.cancel();
                    }
                    return true;
                default:
                    return false;
            }
        }

        private Pk.Bitfield transaction_flags(bool simulate) {
            if (simulate)
                return Pk.Bitfield.from_enums(Pk.TransactionFlag.ONLY_TRUSTED, Pk.TransactionFlag.SIMULATE, -1);
            return Pk.Bitfield.from_enums(Pk.TransactionFlag.ONLY_TRUSTED, -1);
        }

        private void begin_activity(Activity next) {
            activity = next;
            percentage = -1;
            allow_cancel = false;
            cancel_requested = false;
            waiting_for_auth = false;
            cancellable = new GLib.Cancellable();
        }

        private async void run_trial() {
            string[] removed = {};
            try {
                var results = yield get_client().install_packages_async(transaction_flags(true), { target_id }, cancellable, on_progress);
                if (results.get_exit_code() != Pk.Exit.SUCCESS) {
                    end_transaction(results.get_exit_code() == Pk.Exit.CANCELLED ? null : error_details(results));
                    return;
                }
                foreach (var package in results.get_package_array()) {
                    var info = package.get_info();
                    if ((info == Pk.Info.REMOVING || info == Pk.Info.OBSOLETING) && package.get_name() != target_name)
                        removed += package.get_name();
                }
            } catch (GLib.Error e) {
                end_transaction(is_cancellation(e) ? null : e.message);
                return;
            }

            if (cancel_requested) {
                end_transaction(null);
                return;
            }

            // On the apps page an install always asks first: Enter there usually launches something
            if (removed.length == 0)
                prompt_text = "Install %s? Enter to confirm, Escape to cancel.".printf(target_name);
            else
                prompt_text = FeatureCatalogue.install_prompt(target_name, removed);
            activity = Activity.PROMPT;
            state_changed();
        }

        private async void run_transaction() {
            begin_activity(Activity.TRANSACTION);
            prompt_text = null;
            update_input_sharing();
            state_changed();

            string ? details = null;
            try {
                var results = yield get_client().install_packages_async(transaction_flags(false), { target_id }, cancellable, on_progress);
                if (results.get_exit_code() != Pk.Exit.SUCCESS && results.get_exit_code() != Pk.Exit.CANCELLED)
                    details = error_details(results);
            } catch (GLib.Error e) {
                if (!is_cancellation(e))
                    details = e.message;
            }
            end_transaction(details);
        }

        private void end_transaction(string ? details) {
            if (details != null) {
                failed_name = target_name;
                failed_details = details;
            }
            end_activity(Activity.REFRESHING);
            refresh_catalogue();
        }

        private void end_activity(Activity next) {
            activity = next;
            waiting_for_auth = false;
            update_input_sharing();
            if (next == Activity.IDLE)
                target_name = null;
            target_id = null;
            prompt_text = null;
            cancellable = null;
            state_changed();
        }

        // See the PR's FeaturesPage: the authorisation window needs the keyboard ilia holds
        private void update_input_sharing() {
            bool shared = activity == Activity.TRANSACTION && (is_wayland || waiting_for_auth);
            if (shared == input_shared)
                return;
            input_shared = shared;
            session_controller.share_input(shared);
        }

        private void on_progress(Pk.Progress progress, Pk.ProgressType type) {
            switch (type) {
                case Pk.ProgressType.ALLOW_CANCEL:
                    allow_cancel = progress.get_allow_cancel();
                    break;
                case Pk.ProgressType.PERCENTAGE:
                    percentage = progress.get_percentage();
                    if (activity == Activity.TRANSACTION)
                        state_changed();
                    break;
                case Pk.ProgressType.STATUS:
                    waiting_for_auth = progress.get_status() == Pk.Status.WAITING_FOR_AUTH;
                    update_input_sharing();
                    break;
                default:
                    break;
            }
        }

        private bool is_cancellation(GLib.Error e) {
            return cancel_requested && e is GLib.IOError.CANCELLED ||
                   e.domain == Pk.ClientError.quark() && e.code == 0xff + Pk.ErrorEnum.TRANSACTION_CANCELLED;
        }

        private static string error_details(Pk.Results results) {
            var error = results.get_error_code();
            if (error != null && error.get_details() != null)
                return error.get_details();
            return results.get_exit_code().enum_to_string();
        }
    }
}
