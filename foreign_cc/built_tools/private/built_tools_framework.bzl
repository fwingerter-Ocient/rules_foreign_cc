"""A module defining a common framework for "built_tools" rules"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("//foreign_cc/private:detect_root.bzl", "detect_root")
load("//foreign_cc/private:framework.bzl", "get_env_prelude", "wrap_outputs")
load("//foreign_cc/private/framework:helpers.bzl", "convert_shell_script", "shebang")

# Common attributes for all built_tool rules
FOREIGN_CC_BUILT_TOOLS_ATTRS = {
    "env": attr.string_dict(
        doc = "Environment variables to set during the build.",
        default = {},
    ),
    "srcs": attr.label(
        doc = "The target containing the build tool's sources",
        mandatory = True,
    ),
    "_cc_toolchain": attr.label(
        default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
    ),
    "_foreign_cc_framework_platform": attr.label(
        doc = "Information about the execution platform",
        cfg = "exec",
        default = Label("@rules_foreign_cc//foreign_cc/private/framework:platform_info"),
    ),
}

# Common fragments for all built_tool rules
FOREIGN_CC_BUILT_TOOLS_FRAGMENTS = [
    "cpp",
]

# Common host fragments for all built_tool rules
FOREIGN_CC_BUILT_TOOLS_HOST_FRAGMENTS = [
    "cpp",
]

def built_tool_rule_impl(ctx, script_lines, out_dir, mnemonic):
    """Framework function for bootstrapping C/C++ build tools.

    This macro should be shared by all "built-tool" rules defined in rules_foreign_cc.
    Any rule implementing this function should ensure that the appropriate artifacts
    are placed in a directory represented by the `INSTALLDIR` environment variable.

    Args:
        ctx (ctx): The current rule's context object
        script_lines (list): A list of lines of a bash script for building the build tool
        out_dir (File): The output directory of the build tool
        mnemonic (str): The mnemonic of the build action

    Returns:
        list: A list of providers
    """

    root = detect_root(ctx.attr.srcs)
    lib_name = ctx.attr.name
    env_prelude = get_env_prelude(ctx, lib_name, [], "")

    cc_toolchain = find_cpp_toolchain(ctx)

    script = env_prelude + [
        "##script_prelude##",
        "export EXT_BUILD_ROOT=##pwd##",
        "export INSTALLDIR=$$EXT_BUILD_ROOT$$/{}".format(out_dir.path),
        "export BUILD_TMPDIR=$$INSTALLDIR$$.build_tmpdir",
        "##mkdirs## $$BUILD_TMPDIR$$",
        "##copy_dir_contents_to_dir## ./{} $$BUILD_TMPDIR$$".format(root),
        "cd $$BUILD_TMPDIR$$",
    ]

    script.append("##enable_tracing##")
    script.extend(script_lines)
    script.append("##disable_tracing##")

    script_text = "\n".join([
        shebang(ctx),
        convert_shell_script(ctx, script),
        "",
    ])

    wrapped_outputs = wrap_outputs(ctx, lib_name, mnemonic, script_text)

    tools = depset(
        [wrapped_outputs.wrapper_script_file, wrapped_outputs.script_file],
        transitive = [cc_toolchain.all_files],
    )

    # The use of `run_shell` here is intended to ensure bash is correctly setup on windows
    # environments. This should not be replaced with `run` until a cross platform implementation
    # is found that guarantees bash exists or appropriately errors out.
    ctx.actions.run_shell(
        mnemonic = mnemonic,
        inputs = ctx.attr.srcs.files,
        outputs = [out_dir, wrapped_outputs.log_file],
        tools = tools,
        use_default_shell_env = True,
        command = wrapped_outputs.wrapper_script_file.path,
        execution_requirements = {"block-network": ""},
    )

    return [
        DefaultInfo(files = depset([out_dir])),
        OutputGroupInfo(
            log_file = depset([wrapped_outputs.log_file]),
            script_file = depset([wrapped_outputs.script_file]),
            wrapper_script_file = depset([wrapped_outputs.wrapper_script_file]),
        ),
    ]
