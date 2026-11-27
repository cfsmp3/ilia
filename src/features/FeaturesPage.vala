using Gtk;

namespace Ilia {
    /**
     * Lists Regolith's optional feature packages for the running session. Enter opens a terminal
     * that installs the highlighted package with apt, or removes it if it is installed, and the
     * launcher closes, as after launching anything else: apt shows what the change would do,
     * asks for the password and for confirmation itself. Nothing is asked of PackageKit, which
     * gives the list, until the page is first shown.
     */
    class FeaturesPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 4;
        private const int ITEM_VIEW_COLUMN_KIND = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_SUMMARY = 2;
        private const int ITEM_VIEW_COLUMN_STATE = 3;

        private const string UNAVAILABLE_TEXT = "Package management is not available";

        // Run in the terminal with the apt command and the package: the window stays until Enter, so
        // the outcome can be read
        private const string TERMINAL_SCRIPT = "sudo apt \"$1\" \"$2\"; status=$?; echo; " +
                                               "printf 'Press Enter to close this window.'; read -r _; exit $status";

        // The widget to display list of available options
        private Gtk.TreeView item_view;
        // Model for selections
        private Gtk.ListStore model;
        // View on model of filtered elements
        private Gtk.TreeModelFilter filter;
        private Gtk.TreePath path;
        private Gtk.Widget root_widget;
        private Gtk.Entry entry;
        private SessionContoller session_controller;

        private FeatureSession session;
        // Created when the page is first shown
        private Pk.Client ? client = null;
        private bool catalogue_requested = false;
        // False when the catalogue could not be obtained
        private bool available = true;
        private Gee.HashMap<string, FeaturePackage> packages = new Gee.HashMap<string, FeaturePackage>();

        // Set once a terminal is started; the page closes afterwards
        private bool launching = false;

        public string get_name() {
            return "F<u>e</u>atures";
        }

        public string get_icon_name() {
            return "system-software-install";
        }

        public string get_help() {
            return "This dialog lists the optional Regolith features for the running session: looks, bar blocks, compositors and window manager extensions. Installed features are marked. Enter opens a terminal that installs the selected feature with apt, or removes it if it is installed; apt shows what else would change and asks before changing anything.";
        }

        public char get_keybinding() {
            return 'e';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Install or Remove Package in a Terminal");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;
            this.session = FeatureSession.from_wm_name(wm_name);

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (string), typeof (string), typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();
            path = new Gtk.TreePath.first();

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.get_style_context().add_class("scrolled_window");
            scrolled.add(item_view);
            scrolled.expand = true;
            root_widget = scrolled;
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        // Initialize the view displaying selections: one line per package, as on the other pages
        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(filter);
            item_view.get_style_context().add_class("item_view");

            // Do not show column headers
            item_view.headers_visible = false;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            item_view.insert_column_with_attributes(-1, "Kind", new CellRendererText(), "text", ITEM_VIEW_COLUMN_KIND);
            item_view.insert_column_with_attributes(-1, "Name", new CellRendererText(), "text", ITEM_VIEW_COLUMN_NAME);
            var summary_renderer = new CellRendererText();
            summary_renderer.ellipsize = Pango.EllipsizeMode.END;
            var summary_column = new Gtk.TreeViewColumn.with_attributes("Summary", summary_renderer, "text", ITEM_VIEW_COLUMN_SUMMARY);
            summary_column.expand = true;
            item_view.append_column(summary_column);
            item_view.insert_column_with_attributes(-1, "State", new CellRendererText(), "text", ITEM_VIEW_COLUMN_STATE);

            item_view.get_selection().set_mode(SelectionMode.SINGLE);
            item_view.row_activated.connect((row_path, column) => {
                activate_selection();
            });
        }

        public void show() {
            // The first appearance of the page loads the catalogue
            if (!catalogue_requested) {
                catalogue_requested = true;
                load_catalogue();
            }
            item_view.grab_focus();
        }

        public void on_entry_changed() {
            filter.refilter();
            select_first_row(item_view, path);
        }

        // Enter is handled in key_event, which runs first
        public void on_entry_activated() {
        }

        public bool key_event(Gdk.EventKey event_key) {
            if (is_enter_key(event_key.keyval)) {
                activate_selection();
                return true;
            }

            return handle_emacs_vim_nav(item_view, path, event_key);
        }

        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            if (!available)
                return true;
            string name, summary;
            m.@get(iter, ITEM_VIEW_COLUMN_NAME, out name, ITEM_VIEW_COLUMN_SUMMARY, out summary);
            return FeatureCatalogue.matches(entry.get_text(), name ?? "", summary ?? "");
        }

        private void load_catalogue() {
            client = new Pk.Client();
            var filters = Pk.Bitfield.from_enums(Pk.Filter.ARCH, Pk.Filter.NEWEST, -1);

            client.get_packages_async.begin(filters, null, (progress, type) => {}, (obj, res) => {
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
                        stderr.printf("Unable to list packages: %s\n", results.get_exit_code().enum_to_string());
                    }
                } catch (GLib.Error e) {
                    stderr.printf("Unable to list packages: %s\n", e.message);
                }
                show_catalogue(catalogue);
            });
        }

        // Show the packages of catalogue; null if it could not be obtained
        private void show_catalogue(FeatureCatalogue ? catalogue) {
            packages.clear();
            model.clear();
            available = catalogue != null;
            Gtk.TreeIter iter;
            if (catalogue == null) {
                // The placeholder row: nothing to select or act upon
                model.append(out iter);
                model.set(iter, ITEM_VIEW_COLUMN_KIND, "", ITEM_VIEW_COLUMN_NAME, "", ITEM_VIEW_COLUMN_SUMMARY, UNAVAILABLE_TEXT, ITEM_VIEW_COLUMN_STATE, "");
                return;
            }

            foreach (var package in catalogue.get_packages()) {
                packages.set(package.name, package);
                model.append(out iter);
                model.set(
                    iter,
                    ITEM_VIEW_COLUMN_KIND, package.kind.to_label(),
                    ITEM_VIEW_COLUMN_NAME, package.name,
                    ITEM_VIEW_COLUMN_SUMMARY, package.summary,
                    ITEM_VIEW_COLUMN_STATE, package.installed ? "Installed" : ""
                );
            }
            select_first_row(item_view, path);
        }

        // Enter: open a terminal that installs or removes the selected package, at most once
        private void activate_selection() {
            if (!available || launching)
                return;

            Gtk.TreeModel selected_model;
            Gtk.TreeIter iter;
            if (!item_view.get_selection().get_selected(out selected_model, out iter))
                return;
            string name;
            selected_model.@get(iter, ITEM_VIEW_COLUMN_NAME, out name);
            var package = packages.get(name);
            if (package == null)
                return;

            launching = true;
            try {
                Pid pid;
                Process.spawn_async(null, terminal_argv(package.installed ? "remove" : "install", package.name),
                                    null, SpawnFlags.SEARCH_PATH, null, out pid);
            } catch (GLib.Error e) {
                stderr.printf("Unable to open a terminal for %s: %s\n", package.name, e.message);
            }
            session_controller.quit();
        }

        // x-terminal-emulator running apt, in a systemd scope of its own when systemd-run is available
        private static string[] terminal_argv(string apt_command, string package_name) {
            string[] argv = {};
            if (GLib.Environment.find_program_in_path("systemd-run") != null) {
                string unit_name = "run_ilia_apt_" + Uuid.string_random().slice(0, 8) + ".scope";
                argv = { "systemd-run", "--user", "--scope", "--unit", unit_name };
            }
            foreach (unowned string arg in new string[] { "x-terminal-emulator", "-e", "sh", "-c", TERMINAL_SCRIPT, "sh", apt_command, package_name })
                argv += arg;
            return argv;
        }
    }
}
