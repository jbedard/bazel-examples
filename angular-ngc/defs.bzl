load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@aspect_rules_js//npm:defs.bzl", "npm_package")
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
APPLICATION_HTML_ASSETS = ["favicon.ico"]

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
        ["app/**/*"],
        exclude = test_spec_srcs,
    )

    ng_project(
        name = "_app",
        srcs = srcs,
        deps = deps + APPLICATION_DEPS,
    )

    if len(test_spec_srcs) > 0:
        _unit_tests(
            name = "test",
            tests = test_spec_srcs,
            deps = [":_app"] + test_deps + TEST_DEPS,
        )

    # Application bundles.
    esbuild(
        name = "_dev_bundle",
        entry_point = "main.ts",
        srcs = [":_app"],
        define = {
            "process.env.NODE_ENV": "development",
        },
        output_dir = True,
        splitting = True,
        visibility = ["//visibility:private"],
    )
    esbuild(
        name = "_prod_bundle",
        entry_point = "main.ts",
        srcs = [":_app"],
        define = {
            "process.env.NODE_ENV": "production",
        },
        output_dir = True,
        splitting = True,
        minify = True,
        visibility = ["//visibility:private"],
    )

    # Application index.html files
    html_insert_assets_bin.html_insert_assets(
        name = "_prod_html",
        outs = ["_prod_html/index.html"],
        chdir = package_name(),
        args = [
            "--html=$(execpath :index.html)",
            "--out=$@",
            "--roots=. $(RULEDIR)",
            "--assets",
        ] + ["$(execpath %s)" % s for s in html_assets] + [
            "--scripts --module $(locations :_prod_bundle)/main.js",
        ],
        srcs = [":index.html", ":_prod_bundle"] + html_assets,
    )
    html_insert_assets_bin.html_insert_assets(
        name = "_dev_html",
        outs = ["_dev_html/index.html"],
        args = [
            "--html=$(execpath :index.html)",
            "--out=$@",
            "--roots=. $(RULEDIR)",
            "--assets",
        ] + ["$(execpath %s)" % s for s in html_assets] + [
            "--scripts --module $(locations :_dev_bundle)/main.js",
        ],
        chdir = package_name(),
        srcs = [":index.html", ":_dev_bundle"] + html_assets,
    )

    # Application packages that can be deployed
    # TODO: switch to copy_to_directory to strip the _prod_* dirs
    native.filegroup(
        name = "_prod_pkg",
        srcs = [":_prod_bundle", ":_prod_html"] + html_assets + assets,
        visibility = ["//visibility:private"],
    )
    native.filegroup(
        name = "_dev_pkg",
        srcs = [":_dev_bundle", ":_dev_html"] + html_assets + assets,
        visibility = ["//visibility:private"],
    )

    # HTTP deverser for debugging
    history_server_bin.history_server_binary(
        name = "devserver",
        data = [":_dev_pkg"],
        visibility = visibility,
    )

    # The default target: the prod package
    native.alias(
        name = name,
        actual = "_prod_pkg",
        visibility = visibility,
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

    ng_project(
        name = "_lib",
        srcs = srcs,
        deps = deps + LIBRARY_DEPS,
        visibility = ["//visibility:private"],
    )

    # A package.json pointing to the public_api.js as the package entry point
    # TODO: TBD: could also write an index.js file, or drop the public_api.ts convention for index.ts
    write_file(
        name = "_package_json",
        out = "package.json",
        content = ["""{"name": "%s", "main": "./public-api.js", "types": "./public-api.d.ts"}""" % package_name],
        visibility = ["//visibility:private"],
    )

    # Output the library as an npm package that can be linked.
    npm_package(
        name = "_pkg",
        package = package_name,
        root_paths = [
            native.package_name(),
            "%s/src" % native.package_name(),
        ],
        srcs = [":_lib", ":_package_json"],
        visibility = ["//visibility:private"],
    )

    # The primary public library target. Aliased to allow "_pkg" as the npm_package()
    # name and therefore also output directory.
    native.alias(
        name = name,
        actual = "_pkg",
        visibility = visibility,
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
