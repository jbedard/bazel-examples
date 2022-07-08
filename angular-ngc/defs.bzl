load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@aspect_rules_js//js:defs.bzl", "js_library")
load("@aspect_bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")
load("@aspect_rules_ts//ts:defs.bzl", _ts_project = "ts_project")
load("@aspect_rules_esbuild//esbuild:defs.bzl", "esbuild")
load("@npm//:history-server/package_json.bzl", history_server_bin = "bin")
load("@npm//:html-insert-assets/package_json.bzl", html_insert_assets_bin = "bin")

# Common dependencies of Angular applications
APPLICATION_DEPS = [
    "//:node_modules/@angular/common",
    "//:node_modules/@angular/core",
    "//:node_modules/@angular/router",
    "//:node_modules/@angular/platform-browser",
    "//:node_modules/rxjs",
    "//:node_modules/tslib",
    "//:node_modules/zone.js",
]
APPLICATION_HTML_ASSETS = ["styles.css", "favicon.ico"]

# Common dependencies of Angular libraries
LIBRARY_DEPS = [
    "//:node_modules/@angular/common",
    "//:node_modules/@angular/core",
    "//:node_modules/@angular/router",
    "//:node_modules/rxjs",
    "//:node_modules/tslib",
]

# Common dependencies of Angular test suites using jasmine
TEST_CONFIG = [
    "//:karma.conf.js",
    "//:node_modules/@types/jasmine",
    "//:node_modules/karma-chrome-launcher",
    "//:node_modules/karma",
    "//:node_modules/karma-jasmine",
    "//:node_modules/karma-jasmine-html-reporter",
    "//:node_modules/karma-coverage",
]
TEST_DEPS = APPLICATION_DEPS + [
    "//:node_modules/@angular/compiler",
    "//:node_modules/@types/jasmine",
    "//:node_modules/jasmine-core",
]

def ts_project(name, **kwargs):
    _ts_project(
        name = name,

        # Default tsconfig and aligning attributes
        tsconfig = kwargs.pop("tsconfig", "//:tsconfig"),
        declaration = kwargs.pop("declaration", True),
        declaration_map = kwargs.pop("declaration_map", True),
        source_map = kwargs.pop("source_map", True),
        **kwargs
    )

def ng_project(name, **kwargs):
    """The rules_js ts_project() configured with the Angular ngc compiler.
    """
    ts_project(
        name = name,

        # Compiler
        tsc = "//:ngc",
        supports_workers = False,

        # Any other ts_project() or generic args
        **kwargs
    )

def ng_application(name, deps = [], test_deps = [], assets = None, html_assets = None, visibility = ["//visibility:public"], **kwargs):
    """
    Bazel macro for compiling an Angular application. Creates {name}, test, devserver targets.

    Projects structure:
      main.ts
      index.html
      polyfills.ts (optional)
      styles.css (optional)
      app/
        **/*.{ts,css,html}

    Tests:
      app/
        **/*.spec.ts

    Args:
      name: the rule name
      deps: dependencies of the library
      test_deps: additional dependencies for tests
      html_assets: assets to insert into the index.html
      assets: assets to include in the file bundle
      visibility: visibility of the primary targets ({name}, 'test', 'devserver')
      **kwargs: extra args passed to main Angular CLI rules
    """
    assets = assets if assets else native.glob(["assets/**/*"])
    html_assets = html_assets if html_assets else APPLICATION_HTML_ASSETS

    test_spec_srcs = native.glob(["app/**/*.spec.ts"])

    srcs = native.glob(
        ["main.ts", "app/**/*"],
        exclude = test_spec_srcs,
    )

    ng_project(
        name = "_app",
        srcs = srcs,
        deps = deps + APPLICATION_DEPS,
        visibility = ["//visibility:private"],
    )

    if len(test_spec_srcs) > 0:
        _unit_tests(
            name = "test",
            tests = test_spec_srcs,
            deps = [":_app"] + test_deps + TEST_DEPS,
        )

    _pkg_web(
        name = "prod",
        entry_point = "main.js",
        entry_deps = [":_app"],
        html_assets = html_assets,
        assets = assets,
        production = True,
    )

    _pkg_web(
        name = "dev",
        entry_point = "main.js",
        entry_deps = [":_app"],
        html_assets = html_assets,
        assets = assets,
        production = False,
    )

    # devserser
    history_server_bin.history_server_binary(
        name = "devserver",
        args = ["$(location :dev)"],
        data = [":dev"],
        visibility = visibility,
    )

    # # The default target: the prod package
    # native.alias(
    #     name = name,
    #     actual = "_prod_pkg",
    #     visibility = visibility,
    # )


def _pkg_web(name, entry_point, entry_deps = [], html_assets = [], assets = [], define = {}, production = False):
    """ Bundle and create runnable web package.

      For a given application entry_point, assets and defined constants... generate
      a bundle using that entry and constants, an index.html referencing the bundle and
      providated assets, package all content into a resulting directory of the given name.
    """

    # Adjust based/append on production flag
    define_combined = {
        "process.env.NODE_ENV": "production" if production else "development",
        "ngDevMode": "false" if production else "true",
    }
    define_combined.update(define.items())

    bundle = "bundle-%s" % name

    esbuild(
        name = bundle,
        entry_points = [entry_point],
        srcs = entry_deps,
        define = define_combined,
        format = "esm",
        output_dir = True,
        splitting = True,
        minify = True,
        visibility = ["//visibility:private"],
    )

    html_out = "_%s_html" % name

    html_insert_assets_bin.html_insert_assets(
        name = html_out,
        outs = ["%s/index.html" % html_out],
        args = [
          # Template HTML file.
          "--html", "$(location :index.html)",
          # Output HTML file.
          "--out", "%s/%s/index.html" % (native.package_name(), html_out),
          # Root directory prefixes to strip from asset paths.
          "--roots", native.package_name(), "%s/%s" % (native.package_name(), html_out)
        ]
        # Generic Assets
        + ["--assets"] + ["$(execpath %s)" % s for s in html_assets]
        # TODO: zonejs at the top
        # Main bundle
        + ["--scripts", "--module", "%s/main.js" % bundle],
        # The input HTML template, all assets for potential access for stamping
        srcs = [":index.html", ":%s" % bundle] + html_assets,
        visibility = ["//visibility:private"],
    )

    copy_to_directory(
        name = name,
        srcs = [":%s" % bundle, ":%s" % html_out] + html_assets + assets,
        exclude_prefixes = ["%s_metadata.json" % bundle],
        root_paths = [".", "%s/%s" % (native.package_name(), html_out)],
        visibility = ["//visibility:private"],
    )


def ng_library(name, package_name = None, deps = [], test_deps = [], visibility = ["//visibility:public"]):
    """
    Bazel macro for compiling an NG library project. Creates {name} and test targets.

    Projects structure:
      src/
        public_api.ts
        **/*.{ts,css,html}

    Tests:
      src/
        **/*.spec.ts

    Args:
      name: the rule name
      package_name: the package name
      deps: dependencies of the library
      test_deps: additional dependencies for tests
      visibility: visibility of the primary targets ({name}, 'test')
    """

    test_spec_srcs = native.glob(["src/**/*.spec.ts"])

    srcs = native.glob(
        ["src/**/*.ts", "src/**/*.css", "src/**/*.html"],
        exclude = test_spec_srcs,
    )

    # An index file to allow direct imports of the directory similar to a package.json "main"
    write_file(
        name = "_index",
        out = "index.ts",
        content = ["export * from \"./src/public-api\";"],
        visibility = ["//visibility:private"],
    )

    ng_project(
        name = "_lib",
        srcs = srcs + [":_index"],
        deps = deps + LIBRARY_DEPS,
        visibility = ["//visibility:private"],
    )

    js_library(
        name = name,
        deps = [":_lib"],
        visibility = ["//visibility:public"],
    )

    if len(test_spec_srcs) > 0:
        _unit_tests(
            name = "test",
            tests = test_spec_srcs,
            deps = [":_lib"] + test_deps + TEST_DEPS,
        )

def _unit_tests(name, tests, deps = []):
    ng_project(
        name = "_tests",
        srcs = tests,
        deps = deps,
        testonly = 1,
        visibility = ["//visibility:private"],
    )

    # Bundle the spec files
    esbuild(
        name = "_test_bundle",
        testonly = 1,
        entry_points = [spec.replace(".ts", ".js") for spec in tests],
        deps = [":_tests"],
        output_dir = True,
        splitting = True,
        visibility = ["//visibility:private"],
    )

    # TODO: create '{name}' target to actually run/test the tests
