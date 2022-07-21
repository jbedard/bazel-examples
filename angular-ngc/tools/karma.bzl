load(":util.bzl", "to_manifest_path")
load("@aspect_bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")
load("@bazel_skylib//rules:copy_file.bzl", "copy_file")

# Generate a karma.config.js file to:
# - run the given bundle containing specs
# - serve the given assets via http
# - bootstrap a set of js files before the bundle
def _generate_karma_config_impl(ctx):
    configuration = ctx.outputs.configuration

    # root-relative (runfiles) path to the directory containing karma.conf
    config_segments = len(configuration.short_path.split("/"))

    ctx.actions.expand_template(
        template = ctx.file._conf_tmpl,
        output = configuration,
        substitutions = {
            "TMPL_bootstrap_files": "\n  ".join(["'%s'," % to_manifest_path(ctx, e) for e in ctx.files.bootstrap_bundles]),
            "TMPL_runfiles_path": "/".join([".."] * config_segments),
            "TMPL_static_files": "\n  ".join(["'%s'," % to_manifest_path(ctx, e) for e in ctx.files.static_files]),
            "TMPL_spec_files": "\n  ".join(["'%s'," % to_manifest_path(ctx, e) for e in ctx.files.test_bundles]),
            # "TMPL_test_bundle_dir": "\n  ".join(["'%s'," % _to_manifest_path(ctx, e) for e in ctx.files.bundle]),
            # "TMPL_spec_files": "\n  ".join(["'%s'," % to_manifest_path(ctx, e) for e in ctx.files.specs]),
        },
    )

generate_karma_config = rule(
    implementation = _generate_karma_config_impl,
    attrs = {
        # https://github.com/bazelbuild/rules_nodejs/blob/3.3.0/packages/concatjs/web_test/karma_web_test.bzl#L34-L39
        "bootstrap_bundles": attr.label_list(
            doc = """JavaScript files to load via <script> *before* the specs""",
            allow_files = [".js"],
        ),
        "test_bundles": attr.label_list(
            doc = """The label producing the bundle directory containing the specs""",
        ),
        # https://github.com/bazelbuild/rules_nodejs/blob/3.3.0/packages/concatjs/web_test/karma_web_test.bzl#L81-L87
        "static_files": attr.label_list(
            doc = """Arbitrary files which are available to be served on request""",
            allow_files = True,
        ),

        # https://github.com/bazelbuild/rules_nodejs/blob/3.3.0/packages/concatjs/web_test/karma_web_test.bzl#L88-L91
        "_conf_tmpl": attr.label(
            doc = """the karma config template""",
            cfg = "exec",
            allow_single_file = True,
            default = Label("//tools:karma.conf.js"),
        ),
    },
    outputs = {
        "configuration": "%{name}.cjs",
    },
)

def generate_test_bootstrap(name):
    copy_to_directory(
        name = name,
        srcs = ["//tools:test_bootstrap"],
        testonly = 1,
        exclude_prefixes = ["test_bootstrap_metadata.json"],  #TODO: delete after https://github.com/aspect-build/rules_esbuild/commit/f3def5493814845ad1f7863dde5ba21c12f424b8
        root_paths = ["tools/test_bootstrap"],
    )

def generate_test_setup(name):
    copy_file(
        name = name,
        out = "%s.ts" % name,
        testonly = 1,
        src = "//tools:test-setup.ts",
    )
