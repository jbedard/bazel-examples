load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@aspect_rules_js//js:defs.bzl", "js_library")
load("@aspect_rules_ts//ts:defs.bzl", _ts_project = "ts_project")
load("@aspect_rules_esbuild//esbuild:defs.bzl", "esbuild")

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

def ng_application(name, deps = [], test_deps = [], **kwargs):
    """
    Bazel macro for compiling an NG application project. Creates {name}, test, serve targets.

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
      **kwargs: extra args passed to main Angular CLI rules
    """
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

    # Bundle the app
    esbuild(
        name = "_bundle",
        entry_points = ["main.js"],
        srcs = [":_app"],
        output_dir = True,
        splitting = True,
        visibility = ["//visibility:private"],
    )


def ng_library(name, package_name, deps = [], test_deps = [], visibility = ["//visibility:public"]):
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
        ng_project(
            name = "_tests",
            srcs = test_spec_srcs,
            deps = [":_lib"] + test_deps + TEST_DEPS,
            testonly = 1,
            visibility = ["//visibility:private"],
        )

        # Bundle the spec files
        esbuild(
            name = "_test_bundle",
            testonly = 1,
            entry_points = [spec.replace(".ts", ".js") for spec in test_spec_srcs],
            deps = [":_tests"],
            output_dir = True,
            splitting = True,
            visibility = ["//visibility:private"],
        )
