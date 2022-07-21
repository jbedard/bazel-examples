load("@npm//:prettier/package_json.bzl", _prettier_bin = "bin")
load("@aspect_bazel_lib//lib:copy_file.bzl", "copy_file")

def prettier(name, srcs):
    copy_file(
        name = "_copy_prettier_rc",
        src = "//tools:.prettierrc.json",
        out = "prettierrc.json",
    )
    _prettier_bin.prettier_binary(
        name = name,
        data = srcs + [":_copy_prettier_rc"],
        args = [
            "--config",
            "$(location :_copy_prettier_rc)",
            "--loglevel",
            "debug",
            "--write",
        ],
    )
