# Execution platform for the local REAPI shim (Apple Container VMs).
#
# remote_enabled = True routes all genrule actions through the REAPI shim at
# grpc://localhost:8980, which executes them inside ephemeral Apple Container
# VMs running the specified container image.
#
# local_enabled = False ensures nothing silently falls back to unsandboxed
# host execution.

def _re_platform_impl(ctx):
    name = ctx.label.raw_target()
    cfg = ConfigurationInfo(constraints = {}, values = {})
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = CommandExecutorConfig(
            local_enabled = False,
            remote_enabled = True,
            remote_execution_properties = {
                "OSFamily": "linux",
                "ISA": "aarch64",
            },
            remote_execution_use_case = "buck2-default",
        ),
    )
    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(name), configuration = cfg),
        ExecutionPlatformRegistrationInfo(platforms = [platform]),
    ]

re_platform = rule(
    impl = _re_platform_impl,
    attrs = {},
)
