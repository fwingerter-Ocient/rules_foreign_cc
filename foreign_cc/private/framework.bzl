""" Contains definitions for creation of external C/C++ build rules (for building external libraries
 with CMake, configure/make, autotools)
"""

load("@bazel_skylib//lib:collections.bzl", "collections")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("//foreign_cc:providers.bzl", "ForeignCcArtifactInfo", "ForeignCcDepsInfo")
load("//foreign_cc/private:detect_root.bzl", "detect_root", "filter_containing_dirs_from_inputs")
load(
    "//foreign_cc/private/framework:helpers.bzl",
    "convert_shell_script",
    "create_function",
    "escape_dquote_bash",
    "script_extension",
    "shebang",
)
load("//foreign_cc/private/framework:platform.bzl", "os_name")
load(
    ":cc_toolchain_util.bzl",
    "LibrariesToLinkInfo",
    "create_linking_info",
    "get_env_vars",
    "targets_windows",
)
load(
    ":run_shell_file_utils.bzl",
    "copy_directory",
)

# Dict with definitions of the context attributes, that customize cc_external_rule_impl function.
# Many of the attributes have default values.
#
# Typically, the concrete external library rule will use this structure to create the attributes
# description dict. See cmake.bzl as an example.
#
CC_EXTERNAL_RULE_ATTRIBUTES = {
    "additional_inputs": attr.label_list(
        doc = (
            "__deprecated__: Please use the `build_data` attribute."
        ),
        mandatory = False,
        allow_files = True,
        default = [],
    ),
    "additional_tools": attr.label_list(
        doc = (
            "__deprecated__: Please use the `build_data` attribute."
        ),
        mandatory = False,
        allow_files = True,
        cfg = "exec",
        default = [],
    ),
    "alwayslink": attr.bool(
        doc = (
            "Optional. if true, link all the object files from the static library, " +
            "even if they are not used."
        ),
        mandatory = False,
        default = False,
    ),
    "build_data": attr.label_list(
        doc = "Files needed by this rule only during build/compile time. May list file or rule targets. Generally allows any target.",
        mandatory = False,
        allow_files = True,
        cfg = "exec",
        default = [],
    ),
    "copts": attr.string_list(
        doc = "Optional. Add these options to the compile flags passed to the foreign build system. The flags only take affect for compiling this target, not its dependencies.",
        mandatory = False,
        default = [],
    ),
    "data": attr.label_list(
        doc = "Files needed by this rule at runtime. May list file or rule targets. Generally allows any target.",
        mandatory = False,
        allow_files = True,
        cfg = "target",
        default = [],
    ),
    "defines": attr.string_list(
        doc = (
            "Optional compilation definitions to be passed to the dependencies of this library. " +
            "They are NOT passed to the compiler, you should duplicate them in the configuration options."
        ),
        mandatory = False,
        default = [],
    ),
    "deps": attr.label_list(
        doc = (
            "Optional dependencies to be copied into the directory structure. " +
            "Typically those directly required for the external building of the library/binaries. " +
            "(i.e. those that the external build system will be looking for and paths to which are " +
            "provided by the calling rule)"
        ),
        mandatory = False,
        default = [],
        providers = [CcInfo],
    ),
    "env": attr.string_dict(
        doc = (
            "Environment variables to set during the build. " +
            "`$(execpath)` macros may be used to point at files which are listed as `data`, `deps`, or `build_data`, " +
            "but unlike with other rules, these will be replaced with absolute paths to those files, " +
            "because the build does not run in the exec root. " +
            "No other macros are supported." +
            "Variables containing `PATH` (e.g. `PATH`, `LD_LIBRARY_PATH`, `CPATH`) entries will be prepended to the existing variable."
        ),
    ),
    "lib_name": attr.string(
        doc = (
            "Library name. Defines the name of the install directory and the name of the static library, " +
            "if no output files parameters are defined (any of static_libraries, shared_libraries, " +
            "interface_libraries, binaries_names) " +
            "Optional. If not defined, defaults to the target's name."
        ),
        mandatory = False,
    ),
    "lib_source": attr.label(
        doc = (
            "Label with source code to build. Typically a filegroup for the source of remote repository. " +
            "Mandatory."
        ),
        mandatory = True,
        allow_files = True,
    ),
    "linkopts": attr.string_list(
        doc = "Optional link options to be passed up to the dependencies of this library",
        mandatory = False,
        default = [],
    ),
    "out_bin_dir": attr.string(
        doc = "Optional name of the output subdirectory with the binary files, defaults to 'bin'.",
        mandatory = False,
        default = "bin",
    ),
    "out_binaries": attr.string_list(
        doc = "Optional names of the resulting binaries.",
        mandatory = False,
    ),
    "out_data_dirs": attr.string_list(
        doc = "Optional names of additional directories created by the build that should be declared as bazel action outputs",
        mandatory = False,
    ),
    "out_headers_only": attr.bool(
        doc = "Flag variable to indicate that the library produces only headers",
        mandatory = False,
        default = False,
    ),
    "out_include_dir": attr.string(
        doc = "Optional name of the output subdirectory with the header files, defaults to 'include'.",
        mandatory = False,
        default = "include",
    ),
    "out_interface_libs": attr.string_list(
        doc = "Optional names of the resulting interface libraries.",
        mandatory = False,
    ),
    "out_lib_dir": attr.string(
        doc = "Optional name of the output subdirectory with the library files, defaults to 'lib'.",
        mandatory = False,
        default = "lib",
    ),
    "out_shared_libs": attr.string_list(
        doc = "Optional names of the resulting shared libraries.",
        mandatory = False,
    ),
    "out_static_libs": attr.string_list(
        doc = (
            "Optional names of the resulting static libraries. Note that if `out_headers_only`, `out_static_libs`, " +
            "`out_shared_libs`, and `out_binaries` are not set, default `lib_name.a`/`lib_name.lib` static " +
            "library is assumed"
        ),
        mandatory = False,
    ),
    "postfix_script": attr.string(
        doc = "Optional part of the shell script to be added after the make commands",
        mandatory = False,
    ),
    "targets": attr.string_list(
        doc = (
            "A list of targets with in the foreign build system to produce. An empty string (`\"\"`) will result in " +
            "a call to the underlying build system with no explicit target set"
        ),
        mandatory = False,
    ),
    "tool_prefix": attr.string(
        doc = "A prefix for build commands",
        mandatory = False,
    ),
    "tools_deps": attr.label_list(
        doc = "__deprecated__: Please use the `build_data` attribute.",
        mandatory = False,
        allow_files = True,
        cfg = "exec",
        default = [],
    ),
    # we need to declare this attribute to access cc_toolchain
    "_cc_toolchain": attr.label(
        default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
    ),
    "_foreign_cc_framework_platform": attr.label(
        doc = "Information about the execution platform",
        cfg = "exec",
        default = Label("@rules_foreign_cc//foreign_cc/private/framework:platform_info"),
    ),
}

# A list of common fragments required by rules using this framework
CC_EXTERNAL_RULE_FRAGMENTS = [
    "cpp",
]

# buildifier: disable=print
def _print_deprecation_warnings(ctx):
    if ctx.attr.tools_deps:
        print(ctx.label, "Attribute `tools_deps` is deprecated. Please use `build_data`.")

    if ctx.attr.additional_inputs:
        print(ctx.label, "Attribute `additional_inputs` is deprecated. Please use `build_data`.")

    if ctx.attr.additional_tools:
        print(ctx.label, "Attribute `additional_tools` is deprecated. Please use `build_data`.")

# buildifier: disable=function-docstring-header
# buildifier: disable=function-docstring-args
# buildifier: disable=function-docstring-return
def create_attrs(attr_struct, configure_name, create_configure_script, **kwargs):
    """Function for adding/modifying context attributes struct (originally from ctx.attr),
     provided by user, to be passed to the cc_external_rule_impl function as a struct.

     Copies a struct 'attr_struct' values (with attributes from CC_EXTERNAL_RULE_ATTRIBUTES)
     to the resulting struct, adding or replacing attributes passed in 'configure_name',
     'configure_script', and '**kwargs' parameters.
    """
    attrs = {}
    for key in CC_EXTERNAL_RULE_ATTRIBUTES:
        if not key.startswith("_") and hasattr(attr_struct, key):
            attrs[key] = getattr(attr_struct, key)

    attrs["configure_name"] = configure_name
    attrs["create_configure_script"] = create_configure_script

    for arg in kwargs:
        attrs[arg] = kwargs[arg]
    return struct(**attrs)

# buildifier: disable=name-conventions
ConfigureParameters = provider(
    doc = """Parameters of create_configure_script callback function, called by
cc_external_rule_impl function. create_configure_script creates the configuration part
of the script, and allows to reuse the inputs structure, created by the framework.""",
    fields = dict(
        ctx = "Rule context",
        attrs = """Attributes struct, created by create_attrs function above""",
        inputs = """InputFiles provider: summarized information on rule inputs, created by framework
function, to be reused in script creator. Contains in particular merged compilation and linking
dependencies.""",
    ),
)

def get_env_prelude(ctx, lib_name, data_dependencies, target_root):
    """Generate a bash snippet containing environment variable definitions

    Args:
        ctx (ctx): The rule's context object
        lib_name (str): The name of the target being built
        data_dependencies (list): A list of targets representing dependencies
        target_root (str): The path from the root target's directory in the build output

    Returns:
        tuple: A list of environment variables to define in the build script and a dict
            of environment variables
    """
    env_snippet = [
        "export EXT_BUILD_ROOT=##pwd##",
        "export INSTALLDIR=$$EXT_BUILD_ROOT$$/" + target_root + "/" + lib_name,
        "export BUILD_TMPDIR=$$INSTALLDIR$$.build_tmpdir",
        "export EXT_BUILD_DEPS=$$INSTALLDIR$$.ext_build_deps",
    ]

    if os_name(ctx) == "macos":
        env_snippet.extend(["export DEVELOPER_DIR=\"$(xcode-select --print-path)\"", "export SDKROOT=\"$(xcrun --sdk macosx --show-sdk-path)\""])

    env = dict()

    # Add all environment variables from the cc_toolchain
    cc_env = _correct_path_variable(get_env_vars(ctx))
    env.update(cc_env)

    cc_toolchain = find_cpp_toolchain(ctx)
    if cc_toolchain.compiler == "msvc-cl":
        # Prepend PATH environment variable with the path to the toolchain linker, which prevents MSYS using its linker (/usr/bin/link.exe) rather than the MSVC linker (both are named "link.exe")
        linker_path = paths.dirname(cc_toolchain.ld_executable)
        env.update({"PATH": _normalize_path(linker_path) + ":" + env.get("PATH")})

    # Add all user defined variables
    user_vars = expand_locations(ctx, ctx.attr.env, data_dependencies)
    env.update(user_vars)

    # If user has defined a PATH variable (e.g. PATH, LD_LIBRARY_PATH, CPATH) prepend it to the existing variable
    for user_var in user_vars:
        if "PATH" in user_var and cc_env.get(user_var):
            env.update({user_var: user_vars.get(user_var) + ":" + cc_env.get(user_var)})

    env_snippet.extend(["export {}=\"{}\"".format(key, escape_dquote_bash(val)) for key, val in env.items()])

    return env_snippet

def cc_external_rule_impl(ctx, attrs):
    """Framework function for performing external C/C++ building.

    To be used to build external libraries or/and binaries with CMake, configure/make, autotools etc.,
    and use results in Bazel.
    It is possible to use it to build a group of external libraries, that depend on each other or on
    Bazel library, and pass nessesary tools.

    Accepts the actual commands for build configuration/execution in attrs.

    Creates and runs a shell script, which:

    1. prepares directory structure with sources, dependencies, and tools symlinked into subdirectories
        of the execroot directory. Adds tools into PATH.
    2. defines the correct absolute paths in tools with the script paths, see 7
    3. defines the following environment variables:
        EXT_BUILD_ROOT: execroot directory
        EXT_BUILD_DEPS: subdirectory of execroot, which contains the following subdirectories:

        For cmake_external built dependencies:
            symlinked install directories of the dependencies

            for Bazel built/imported dependencies:

            include - here the include directories are symlinked
            lib - here the library files are symlinked
            lib/pkgconfig - here the pkgconfig files are symlinked
            bin - here the tools are copied
        INSTALLDIR: subdirectory of the execroot (named by the lib_name), where the library/binary
        will be installed

        These variables should be used by the calling rule to refer to the created directory structure.
    4. calls 'attrs.create_configure_script'
    5. calls 'attrs.postfix_script'
    6. replaces absolute paths in possibly created scripts with a placeholder value

    Please see cmake.bzl for example usage.

    Args:
        ctx: calling rule context
        attrs: attributes struct, created by create_attrs function above.
            Contains fields from CC_EXTERNAL_RULE_ATTRIBUTES (see descriptions there),
            two mandatory fields:
                - configure_name: name of the configuration tool, to be used in action mnemonic,
                - create_configure_script(ConfigureParameters): function that creates configuration
                    script, accepts ConfigureParameters
            and some other fields provided by the rule, which have been passed to create_attrs.

    Returns:
        A list of providers
    """
    _print_deprecation_warnings(ctx)
    lib_name = attrs.lib_name or ctx.attr.name

    inputs = _define_inputs(attrs)
    outputs = _define_outputs(ctx, attrs, lib_name)
    out_cc_info = _define_out_cc_info(ctx, attrs, inputs, outputs)

    lib_header = "Bazel external C/C++ Rules. Building library '{}'".format(lib_name)

    # We can not declare outputs of the action, which are in parent-child relashion,
    # so we need to have a (symlinked) copy of the output directory to provide
    # both the C/C++ artifacts - libraries, headers, and binaries,
    # and the install directory as a whole (which is mostly nessesary for chained external builds).
    #
    # We want the install directory output of this rule to have the same name as the library,
    # so symlink it under the same name but in a subdirectory
    installdir_copy = copy_directory(ctx.actions, "$$INSTALLDIR$$", "copy_{}/{}".format(lib_name, lib_name))
    target_root = paths.dirname(installdir_copy.file.dirname)

    data_dependencies = ctx.attr.data + ctx.attr.build_data

    # Also add legacy dependencies while they're still available
    data_dependencies += ctx.attr.tools_deps + ctx.attr.additional_tools

    env_prelude = get_env_prelude(ctx, lib_name, data_dependencies, target_root)

    postfix_script = [attrs.postfix_script]
    if not attrs.postfix_script:
        postfix_script = []

    script_lines = [
        "##echo## \"\"",
        "##echo## \"{}\"".format(lib_header),
        "##echo## \"\"",
        "##script_prelude##",
    ] + env_prelude + [
        "##path## $$EXT_BUILD_ROOT$$",
        "##mkdirs## $$INSTALLDIR$$",
        "##mkdirs## $$BUILD_TMPDIR$$",
        "##mkdirs## $$EXT_BUILD_DEPS$$",
    ] + _print_env() + _copy_deps_and_tools(inputs) + [
        "cd $$BUILD_TMPDIR$$",
    ] + attrs.create_configure_script(ConfigureParameters(ctx = ctx, attrs = attrs, inputs = inputs)) + postfix_script + [
        # replace references to the root directory when building ($BUILD_TMPDIR)
        # and the root where the dependencies were installed ($EXT_BUILD_DEPS)
        # for the results which are in $INSTALLDIR (with placeholder)
        "##replace_absolute_paths## $$INSTALLDIR$$ $$BUILD_TMPDIR$$",
        "##replace_absolute_paths## $$INSTALLDIR$$ $$EXT_BUILD_DEPS$$",
        "##replace_sandbox_paths## $$INSTALLDIR$$ $$EXT_BUILD_ROOT$$",
        installdir_copy.script,
        "cd $$EXT_BUILD_ROOT$$",
    ] + [
        "##replace_symlink## {}".format(file.path)
        for file in (
            outputs.libraries.static_libraries +
            outputs.libraries.shared_libraries +
            outputs.libraries.interface_libraries
        )
    ]

    script_text = "\n".join([
        shebang(ctx),
        convert_shell_script(ctx, script_lines),
        "",
    ])
    wrapped_outputs = wrap_outputs(ctx, lib_name, attrs.configure_name, script_text)

    rule_outputs = outputs.declared_outputs + [installdir_copy.file]
    cc_toolchain = find_cpp_toolchain(ctx)

    execution_requirements = {"block-network": ""}
    if "requires-network" in ctx.attr.tags:
        execution_requirements = {"requires-network": ""}

    # TODO: `additional_tools` is deprecated, remove.
    legacy_tools = ctx.files.additional_tools + ctx.files.tools_deps

    # The use of `run_shell` here is intended to ensure bash is correctly setup on windows
    # environments. This should not be replaced with `run` until a cross platform implementation
    # is found that guarantees bash exists or appropriately errors out.
    ctx.actions.run_shell(
        mnemonic = "Cc" + attrs.configure_name.capitalize() + "MakeRule",
        inputs = depset(inputs.declared_inputs),
        outputs = rule_outputs + [wrapped_outputs.log_file],
        tools = depset(
            [wrapped_outputs.script_file, wrapped_outputs.wrapper_script_file] + ctx.files.data + ctx.files.build_data + legacy_tools,
            transitive = [cc_toolchain.all_files] + [data[DefaultInfo].default_runfiles.files for data in data_dependencies],
        ),
        command = wrapped_outputs.wrapper_script_file.path,
        execution_requirements = execution_requirements,
        use_default_shell_env = True,
        progress_message = "Foreign Cc - {configure_name}: Building {lib_name}".format(
            configure_name = attrs.configure_name,
            lib_name = lib_name,
        ),
    )

    # Gather runfiles transitively as per the documentation in:
    # https://docs.bazel.build/versions/master/skylark/rules.html#runfiles
    runfiles = ctx.runfiles(files = ctx.files.data)
    for target in [ctx.attr.lib_source] + ctx.attr.deps + ctx.attr.data:
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)

    # TODO: `additional_inputs` is deprecated, remove.
    for legacy in ctx.attr.additional_inputs:
        runfiles = runfiles.merge(legacy[DefaultInfo].default_runfiles)

    externally_built = ForeignCcArtifactInfo(
        gen_dir = installdir_copy.file,
        bin_dir_name = attrs.out_bin_dir,
        lib_dir_name = attrs.out_lib_dir,
        include_dir_name = attrs.out_include_dir,
    )
    output_groups = _declare_output_groups(installdir_copy.file, outputs.out_binary_files)
    wrapped_files = [
        wrapped_outputs.script_file,
        wrapped_outputs.log_file,
        wrapped_outputs.wrapper_script_file,
    ]
    output_groups[attrs.configure_name + "_logs"] = wrapped_files
    return [
        DefaultInfo(
            files = depset(direct = rule_outputs),
            runfiles = runfiles,
        ),
        OutputGroupInfo(**output_groups),
        ForeignCcDepsInfo(artifacts = depset(
            [externally_built],
            transitive = _get_transitive_artifacts(attrs.deps),
        )),
        CcInfo(
            compilation_context = out_cc_info.compilation_context,
            linking_context = out_cc_info.linking_context,
        ),
    ]

# buildifier: disable=name-conventions
WrappedOutputs = provider(
    doc = "Structure for passing the log and scripts file information, and wrapper script text.",
    fields = {
        "log_file": "Execution log file",
        "script_file": "Main script file",
        "wrapper_script": "Wrapper script text to execute",
        "wrapper_script_file": "Wrapper script file (output for debugging purposes)",
    },
)

# buildifier: disable=function-docstring
def wrap_outputs(ctx, lib_name, configure_name, script_text, build_script_file = None):
    extension = script_extension(ctx)
    build_log_file = ctx.actions.declare_file("{}_foreign_cc/{}.log".format(lib_name, configure_name))
    build_script_file = ctx.actions.declare_file("{}_foreign_cc/build_script{}".format(lib_name, extension))
    wrapper_script_file = ctx.actions.declare_file("{}_foreign_cc/wrapper_build_script{}".format(lib_name, extension))

    ctx.actions.write(
        output = build_script_file,
        content = script_text,
        is_executable = True,
    )

    cleanup_on_success_function = create_function(
        ctx,
        "cleanup_on_success",
        "rm -rf $BUILD_TMPDIR $EXT_BUILD_DEPS",
    )
    cleanup_on_failure_function = create_function(
        ctx,
        "cleanup_on_failure",
        "\n".join([
            "##echo## \"rules_foreign_cc: Build failed!\"",
            "##echo## \"rules_foreign_cc: Keeping temp build directory $$BUILD_TMPDIR$$ and dependencies directory $$EXT_BUILD_DEPS$$ for debug.\"",
            "##echo## \"rules_foreign_cc: Please note that the directories inside a sandbox are still cleaned unless you specify '--sandbox_debug' Bazel command line flag.\"",
            "##echo## \"rules_foreign_cc: Printing build logs:\"",
            "##echo## \"_____ BEGIN BUILD LOGS _____\"",
            "##cat## $$BUILD_LOG$$",
            "##echo## \"_____ END BUILD LOGS _____\"",
            "##echo## \"rules_foreign_cc: Build wrapper script location: $$BUILD_WRAPPER_SCRIPT$$\"",
            "##echo## \"rules_foreign_cc: Build script location: $$BUILD_SCRIPT$$\"",
            "##echo## \"rules_foreign_cc: Build log location: $$BUILD_LOG$$\"",
            "##echo## \"\"",
        ]),
    )
    trap_function = "##cleanup_function## cleanup_on_success cleanup_on_failure"

    build_command_lines = [
        "##assert_script_errors##",
        cleanup_on_success_function,
        cleanup_on_failure_function,
        # the call trap is defined inside, in a way how the shell function should be called
        # see, for instance, linux_commands.bzl
        trap_function,
        "export BUILD_WRAPPER_SCRIPT=\"{}\"".format(wrapper_script_file.path),
        "export BUILD_SCRIPT=\"{}\"".format(build_script_file.path),
        "export BUILD_LOG=\"{}\"".format(build_log_file.path),
        # sometimes the log file is not created, we do not want our script to fail because of this
        "##touch## $$BUILD_LOG$$",
        "##redirect_out_err## $$BUILD_SCRIPT$$ $$BUILD_LOG$$",
    ]
    build_command = "\n".join([
        shebang(ctx),
        convert_shell_script(ctx, build_command_lines),
        "",
    ])

    ctx.actions.write(
        output = wrapper_script_file,
        content = build_command,
        is_executable = True,
    )

    return WrappedOutputs(
        script_file = build_script_file,
        log_file = build_log_file,
        wrapper_script_file = wrapper_script_file,
        wrapper_script = build_command,
    )

def _declare_output_groups(installdir, outputs):
    dict_ = {}
    dict_["gen_dir"] = depset([installdir])
    for output in outputs:
        dict_[output.basename] = [output]
    return dict_

def _get_transitive_artifacts(deps):
    artifacts = []
    for dep in deps:
        foreign_dep = get_foreign_cc_dep(dep)
        if foreign_dep:
            artifacts.append(foreign_dep.artifacts)
    return artifacts

def _print_env():
    return [
        "##echo## \"Environment:______________\"",
        "##env##",
        "##echo## \"__________________________\"",
    ]

def _normalize_path(path):
    # Change Windows style paths to Unix style. E.g. change "C:" to "/c"
    if path[0].isalpha() and path[1] == ":":
        path = path.replace(path[0:2], "/" + path[0].lower())

    return path.replace("\\", "/").replace(";", ":")

def _correct_path_variable(env):
    value = env.get("PATH", "")
    if not value:
        return env
    value = _normalize_path(env.get("PATH", ""))
    env["PATH"] = "$PATH:" + value
    return env

def _depset(item):
    if item == None:
        return depset()
    return depset([item])

def _list(item):
    if item:
        return [item]
    return []

def _copy_deps_and_tools(files):
    lines = []
    lines += _symlink_contents_to_dir("lib", files.libs)
    lines += _symlink_contents_to_dir("include", files.headers + files.include_dirs)

    if files.tools_files:
        lines.append("##mkdirs## $$EXT_BUILD_DEPS$$/bin")
    for tool in files.tools_files:
        lines.append("##symlink_to_dir## $$EXT_BUILD_ROOT$$/{} $$EXT_BUILD_DEPS$$/bin/".format(tool))

    for ext_dir in files.ext_build_dirs:
        lines.append("##symlink_to_dir## $$EXT_BUILD_ROOT$$/{} $$EXT_BUILD_DEPS$$".format(_file_path(ext_dir)))

    lines.append("##children_to_path## $$EXT_BUILD_DEPS$$/bin")
    lines.append("##path## $$EXT_BUILD_DEPS$$/bin")

    return lines

def _symlink_contents_to_dir(dir_name, files_list):
    # It is possible that some duplicate libraries will be passed as inputs
    # to cmake_external or configure_make. Filter duplicates out here.
    files_list = collections.uniq(files_list)
    if len(files_list) == 0:
        return []
    lines = ["##mkdirs## $$EXT_BUILD_DEPS$$/" + dir_name]

    for file in files_list:
        path = _file_path(file).strip()
        if path:
            lines.append("##symlink_contents_to_dir## \
$$EXT_BUILD_ROOT$$/{} $$EXT_BUILD_DEPS$$/{}".format(path, dir_name))

    return lines

def _file_path(file):
    return file if type(file) == "string" else file.path

_FORBIDDEN_FOR_FILENAME = ["\\", "/", ":", "*", "\"", "<", ">", "|"]

def _check_file_name(var):
    if (len(var) == 0):
        fail("Library name cannot be an empty string.")
    for index in range(0, len(var) - 1):
        letter = var[index]
        if letter in _FORBIDDEN_FOR_FILENAME:
            fail("Symbol '%s' is forbidden in library name '%s'." % (letter, var))

# buildifier: disable=name-conventions
_Outputs = provider(
    doc = "Provider to keep different kinds of the external build output files and directories",
    fields = dict(
        out_include_dir = "Directory with header files (relative to install directory)",
        out_binary_files = "Binary files, which will be created by the action",
        libraries = "Library files, which will be created by the action",
        declared_outputs = "All output files and directories of the action",
    ),
)

def _define_outputs(ctx, attrs, lib_name):
    attr_binaries_libs = attrs.out_binaries
    attr_headers_only = attrs.out_headers_only
    attr_interface_libs = attrs.out_interface_libs
    attr_out_data_dirs = attrs.out_data_dirs
    attr_shared_libs = attrs.out_shared_libs
    attr_static_libs = attrs.out_static_libs

    static_libraries = []
    if not attr_headers_only:
        if not attr_static_libs and not attr_shared_libs and not attr_binaries_libs and not attr_interface_libs:
            static_libraries = [lib_name + (".lib" if targets_windows(ctx, None) else ".a")]
        else:
            static_libraries = attr_static_libs

    _check_file_name(lib_name)

    out_include_dir = ctx.actions.declare_directory(lib_name + "/" + attrs.out_include_dir)

    out_data_dirs = []
    for dir in attr_out_data_dirs:
        out_data_dirs.append(ctx.actions.declare_directory(lib_name + "/" + dir.lstrip("/")))

    out_binary_files = _declare_out(ctx, lib_name, attrs.out_bin_dir, attr_binaries_libs)

    libraries = LibrariesToLinkInfo(
        static_libraries = _declare_out(ctx, lib_name, attrs.out_lib_dir, static_libraries),
        shared_libraries = _declare_out(ctx, lib_name, attrs.out_lib_dir, attr_shared_libs),
        interface_libraries = _declare_out(ctx, lib_name, attrs.out_lib_dir, attr_interface_libs),
    )

    declared_outputs = [out_include_dir] + out_data_dirs + out_binary_files
    declared_outputs += libraries.static_libraries
    declared_outputs += libraries.shared_libraries + libraries.interface_libraries

    return _Outputs(
        out_include_dir = out_include_dir,
        out_binary_files = out_binary_files,
        libraries = libraries,
        declared_outputs = declared_outputs,
    )

def _declare_out(ctx, lib_name, dir_, files):
    if files and len(files) > 0:
        return [ctx.actions.declare_file("/".join([lib_name, dir_, file])) for file in files]
    return []

# buildifier: disable=name-conventions
InputFiles = provider(
    doc = (
        "Provider to keep different kinds of input files, directories, " +
        "and C/C++ compilation and linking info from dependencies"
    ),
    fields = dict(
        headers = "Include files built by Bazel. Will be copied into $EXT_BUILD_DEPS/include.",
        include_dirs = (
            "Include directories built by Bazel. Will be copied " +
            "into $EXT_BUILD_DEPS/include."
        ),
        libs = "Library files built by Bazel. Will be copied into $EXT_BUILD_DEPS/lib.",
        tools_files = (
            "Files and directories with tools needed for configuration/building " +
            "to be copied into the bin folder, which is added to the PATH"
        ),
        ext_build_dirs = (
            "Directories with libraries, built by framework function. " +
            "This directories should be copied into $EXT_BUILD_DEPS/lib-name as is, with all contents."
        ),
        deps_compilation_info = "Merged CcCompilationInfo from deps attribute",
        deps_linking_info = "Merged CcLinkingInfo from deps attribute",
        declared_inputs = "All files and directories that must be declared as action inputs",
    ),
)

def _define_inputs(attrs):
    cc_infos = []

    bazel_headers = []
    bazel_system_includes = []
    bazel_libs = []

    # This framework function-built libraries: copy result directories under
    # $EXT_BUILD_DEPS/lib-name
    ext_build_dirs = []

    for dep in attrs.deps:
        external_deps = get_foreign_cc_dep(dep)

        cc_infos.append(dep[CcInfo])

        if external_deps:
            ext_build_dirs += [artifact.gen_dir for artifact in external_deps.artifacts.to_list()]
        else:
            headers_info = _get_headers(dep[CcInfo].compilation_context)
            bazel_headers += headers_info.headers
            bazel_system_includes += headers_info.include_dirs
            bazel_libs += _collect_libs(dep[CcInfo].linking_context)

    # Keep the order of the transitive foreign dependencies
    # (the order is important for the correct linking),
    # but filter out repeating directories
    ext_build_dirs = uniq_list_keep_order(ext_build_dirs)

    tools_roots = []
    tools_files = []
    input_files = []
    for tool in attrs.tools_deps:
        tool_root = detect_root(tool)
        tools_roots.append(tool_root)
        for file_list in tool.files.to_list():
            tools_files += _list(file_list)

    # TODO: Remove, `additional_tools` is deprecated.
    for tool in attrs.additional_tools:
        for file_list in tool.files.to_list():
            tools_files += _list(file_list)

    # TODO: Remove, `additional_inputs` is deprecated.
    for input in attrs.additional_inputs:
        for file_list in input.files.to_list():
            input_files += _list(file_list)

    # These variables are needed for correct C/C++ providers constraction,
    # they should contain all libraries and include directories.
    cc_info_merged = cc_common.merge_cc_infos(cc_infos = cc_infos)
    return InputFiles(
        headers = bazel_headers,
        include_dirs = bazel_system_includes,
        libs = bazel_libs,
        tools_files = tools_roots,
        deps_compilation_info = cc_info_merged.compilation_context,
        deps_linking_info = cc_info_merged.linking_context,
        ext_build_dirs = ext_build_dirs,
        declared_inputs = filter_containing_dirs_from_inputs(attrs.lib_source.files.to_list()) +
                          bazel_libs +
                          tools_files +
                          input_files +
                          cc_info_merged.compilation_context.headers.to_list() +
                          ext_build_dirs,
    )

# buildifier: disable=function-docstring
def uniq_list_keep_order(list):
    result = []
    contains_map = {}
    for item in list:
        if contains_map.get(item):
            continue
        contains_map[item] = 1
        result.append(item)
    return result

def get_foreign_cc_dep(dep):
    return dep[ForeignCcDepsInfo] if ForeignCcDepsInfo in dep else None

# consider optimization here to do not iterate both collections
def _get_headers(compilation_info):
    include_dirs = compilation_info.system_includes.to_list() + \
                   compilation_info.includes.to_list()

    # do not use quote includes, currently they do not contain
    # library-specific information
    include_dirs = collections.uniq(include_dirs)
    headers = []
    for header in compilation_info.headers.to_list():
        path = header.path
        included = False
        for dir_ in include_dirs:
            if path.startswith(dir_):
                included = True
                break
        if not included:
            headers.append(header)
    return struct(
        headers = headers,
        include_dirs = include_dirs,
    )

def _define_out_cc_info(ctx, attrs, inputs, outputs):
    compilation_info = cc_common.create_compilation_context(
        headers = depset([outputs.out_include_dir]),
        system_includes = depset([outputs.out_include_dir.path]),
        includes = depset([]),
        quote_includes = depset([]),
        defines = depset(attrs.defines),
    )
    linking_info = create_linking_info(ctx, attrs.linkopts, outputs.libraries)
    cc_info = CcInfo(
        compilation_context = compilation_info,
        linking_context = linking_info,
    )
    inputs_info = CcInfo(
        compilation_context = inputs.deps_compilation_info,
        linking_context = inputs.deps_linking_info,
    )

    return cc_common.merge_cc_infos(cc_infos = [cc_info, inputs_info])

def _extract_libraries(library_to_link):
    return [
        library_to_link.static_library,
        library_to_link.pic_static_library,
        library_to_link.dynamic_library,
        library_to_link.interface_library,
    ]

def _collect_libs(cc_linking):
    libs = []
    for li in cc_linking.linker_inputs.to_list():
        for library_to_link in li.libraries:
            for library in _extract_libraries(library_to_link):
                if library:
                    libs.append(library)
    return collections.uniq(libs)

def _expand_command_path(binary, path, command):
    if command == binary or command.startswith(binary + " "):
        return command.replace(binary, path, 1)
    else:
        return command

def expand_locations(ctx, expandable, data):
    """Expand locations on a dictionary while ensuring `execpath` is always set to an absolute path

    This function is not expected to be passed to any action.env argument but instead rendered into
    build scripts.

    Args:
        ctx (ctx): The rule's context object
        expandable (dict, list, str): Variables to expand, can be a variety of different types
        data (list): A list of targets

    Returns:
        dict: An expanded dict of environment variables
    """
    if type(expandable) == type(dict()):
        expanded_env = dict()
        for key, value in expandable.items():
            # If `EXT_BUILD_ROOT` exists in the string, we assume the user has added it themselves
            if "EXT_BUILD_ROOT" in value:
                expanded_env.update({key: ctx.expand_location(value, data)})
            else:
                expanded_env.update({key: ctx.expand_location(value.replace("$(execpath ", "$$EXT_BUILD_ROOT$$/$(execpath "), data)})
        return expanded_env
    elif type(expandable) == type(list()):
        expanded_vars = list()
        for value in expandable:
            # If `EXT_BUILD_ROOT` exists in the string, we assume the user has added it themselves
            if "EXT_BUILD_ROOT" in value:
                expanded_vars.append(ctx.expand_location(value, data))
            else:
                expanded_vars.append(ctx.expand_location(value.replace("$(execpath ", "$$EXT_BUILD_ROOT$$/$(execpath "), data))
        return expanded_vars
    elif type(expandable) == type(""):
        # If `EXT_BUILD_ROOT` exists in the string, we assume the user has added it themselves
        if "EXT_BUILD_ROOT" in expandable:
            return ctx.expand_location(expandable, data)
        else:
            return ctx.expand_location(expandable.replace("$(execpath ", "$$EXT_BUILD_ROOT$$/$(execpath "), data)
    else:
        fail("Unsupported type: {}".format(type(expandable)))
