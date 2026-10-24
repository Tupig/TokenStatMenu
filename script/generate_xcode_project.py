#!/usr/bin/env python3
"""Generate a dependency-free native macOS .xcodeproj from the same Swift sources."""

import hashlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
objects = {}


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def obj(name, body):
    objects[ident(name)] = body
    return ident(name)


def refs(values):
    return "(" + ", ".join(values) + ",)"


sources = []
groups = []
# The app compiles the shared widget protocol sources directly: the module has
# no WidgetKit dependency, so both the app and the extension can link it.
for folder in ["TokenStatCore", "TokenStatMenu", "TokenStatWidgetShared"]:
    files = []
    for path in sorted((root / "Sources" / folder).glob("*.swift")):
        key = path.relative_to(root).as_posix()
        ref = obj(
            "file:" + key,
            f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.name}"; sourceTree = "<group>";',
        )
        files.append(ref)
        sources.append(obj("build:" + key, f"isa = PBXBuildFile; fileRef = {ref};"))
    groups.append(
        obj(
            "group:" + folder,
            f'isa = PBXGroup; children = {refs(files)}; path = "Sources/{folder}"; sourceTree = "<group>";',
        )
    )
product = obj(
    "product",
    "isa = PBXFileReference; explicitFileType = wrapper.application; path = TokenStatMenu.app; sourceTree = BUILT_PRODUCTS_DIR;",
)
products = obj(
    "products",
    f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";',
)
resource_files = [
    obj(
        "resource:" + n,
        f'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/{n}"; sourceTree = "<group>";',
    )
    for n in ["Info.plist", "config.example.plist"]
]
icon_ref = obj(
    "resource:AppIcon.icns",
    'isa = PBXFileReference; lastKnownFileType = image.icns; path = "Resources/AppIcon.icns"; sourceTree = "<group>";',
)
resource_files.append(icon_ref)
icon_build = obj(
    "resource-build:AppIcon.icns", f"isa = PBXBuildFile; fileRef = {icon_ref};"
)
main = obj(
    "main",
    f'isa = PBXGroup; children = {refs(groups + resource_files + [products])}; sourceTree = "<group>";',
)
source_phase = obj(
    "sources",
    f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(sources)}; runOnlyForDeploymentPostprocessing = 0;",
)
framework_phase = obj(
    "frameworks",
    "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
)
resource_phase = obj(
    "resources",
    f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({icon_build},); runOnlyForDeploymentPostprocessing = 0;",
)
project_configs, target_configs = [], []
for mode in ["Debug", "Release"]:
    project_configs.append(
        obj(
            "project-config:" + mode,
            f"isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ ARCHS = arm64; MACOSX_DEPLOYMENT_TARGET = 13.0; SDKROOT = macosx; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }};",
        )
    )
    optimization = "-Onone" if mode == "Debug" else "-O"
    target_configs.append(
        obj(
            "target-config:" + mode,
            f'''isa = XCBuildConfiguration; name = {mode}; buildSettings = {{
        PRODUCT_NAME = TokenStatMenu;
        PRODUCT_BUNDLE_IDENTIFIER = com.tupig.TokenStatMenu;
        INFOPLIST_FILE = Resources/Info.plist;
        GENERATE_INFOPLIST_FILE = NO;
        // The app and its embedded extension must present one identical App
        // Group: the container is only shared when both are signed with the
        // same team and the same group entitlement.
        CODE_SIGN_ENTITLEMENTS = Resources/TokenStatMenu.entitlements;
        CODE_SIGN_IDENTITY = "-";
        CODE_SIGN_STYLE = Manual;
        ENABLE_APP_SANDBOX = NO;
        ENABLE_HARDENED_RUNTIME = YES;
        TOKENSTAT_WIDGET_GROUP = "";
        SWIFT_OPTIMIZATION_LEVEL = "{optimization}";
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
    }};''',
        )
    )
project_list = obj(
    "project-list",
    f"isa = XCConfigurationList; buildConfigurations = {refs(project_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;",
)
target_list = obj(
    "target-list",
    f"isa = XCConfigurationList; buildConfigurations = {refs(target_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;",
)
target = obj(
    "target",
    f"""isa = PBXNativeTarget; buildConfigurationList = {target_list};
    buildPhases = ({source_phase}, {framework_phase}, {resource_phase},); buildRules = (); dependencies = ();
    name = TokenStatMenu; productName = TokenStatMenu; productReference = {product}; productType = "com.apple.product-type.application";""",
)
# The production widget extension is embedded in the menu-bar app so a single
# install surface (DMG or Cask) carries both the app and its WidgetKit surface.
widget_files = {}
for folder in ["TokenStatWidgetShared", "TokenStatWidgetExtension"]:
    folder_refs = []
    for path in sorted((root / "Sources" / folder).glob("*.swift")):
        key = path.relative_to(root).as_posix()
        ref = obj(
            "file:" + key,
            f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.name}"; sourceTree = "<group>";',
        )
        widget_files[key] = ref
        folder_refs.append(ref)
    # TokenStatWidgetShared already has a group from the app target loop above.
    if folder != "TokenStatWidgetShared":
        groups.append(
            obj(
                "group:" + folder,
                f'isa = PBXGroup; children = {refs(folder_refs)}; path = "Sources/{folder}"; sourceTree = "<group>";',
            )
        )
widget_resources = []
for name in ["WidgetExtension-Info.plist", "WidgetExtension.entitlements"]:
    key = "widget-resource:" + name
    widget_resources.append(
        obj(
            key,
            f'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/{name}"; sourceTree = "<group>";',
        )
    )
resource_files.extend(widget_resources)
widget_extension_product = obj(
    "widget-extension-product",
    'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = TokenStatMenuWidget.appex; sourceTree = BUILT_PRODUCTS_DIR;',
)

# A separate synthetic-only development app owns the WidgetKit extension. The
# normal menu-bar target above does not link or embed any of these sources.
dev_files = {}
for folder in [
    "TokenStatDevWidgetShared",
    "TokenStatDevWidgetHost",
    "TokenStatDevWidgetExtension",
]:
    folder_refs = []
    for path in sorted((root / "Sources" / folder).glob("*.swift")):
        key = path.relative_to(root).as_posix()
        ref = obj(
            "file:" + key,
            f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.name}"; sourceTree = "<group>";',
        )
        dev_files[key] = ref
        folder_refs.append(ref)
    groups.append(
        obj(
            "group:" + folder,
            f'isa = PBXGroup; children = {refs(folder_refs)}; path = "Sources/{folder}"; sourceTree = "<group>";',
        )
    )
for name in [
    "DevWidgetHost-Info.plist",
    "DevWidgetExtension-Info.plist",
    "DevWidgetHost.entitlements",
    "DevWidgetExtension.entitlements",
]:
    key = "resource:" + name
    resource_files.append(
        obj(
            key,
            f'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/{name}"; sourceTree = "<group>";',
        )
    )
dev_host_product = obj(
    "dev-host-product",
    "isa = PBXFileReference; explicitFileType = wrapper.application; path = TokenStatMenuDevWidgetTest.app; sourceTree = BUILT_PRODUCTS_DIR;",
)
dev_extension_product = obj(
    "dev-extension-product",
    'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = TokenStatDevWidgetTest.appex; sourceTree = BUILT_PRODUCTS_DIR;',
)
objects[products] = (
    f'isa = PBXGroup; children = ({product}, {widget_extension_product}, {dev_host_product}, {dev_extension_product},); name = Products; sourceTree = "<group>";'
)
objects[main] = (
    f'isa = PBXGroup; children = {refs(groups + resource_files + [products])}; sourceTree = "<group>";'
)


def dev_source_phase(name, folders):
    build_files = []
    for folder in folders:
        for path in sorted((root / "Sources" / folder).glob("*.swift")):
            key = path.relative_to(root).as_posix()
            build_files.append(
                obj(
                    "build:" + name + ":" + key,
                    f"isa = PBXBuildFile; fileRef = {dev_files[key]};",
                )
            )
    return obj(
        "sources:" + name,
        f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(build_files)}; runOnlyForDeploymentPostprocessing = 0;",
    )


dev_host_sources = dev_source_phase(
    "dev-host", ["TokenStatDevWidgetShared", "TokenStatDevWidgetHost"]
)
dev_extension_sources = dev_source_phase(
    "dev-extension", ["TokenStatDevWidgetShared", "TokenStatDevWidgetExtension"]
)
dev_host_frameworks = obj(
    "frameworks:dev-host",
    "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
)
dev_extension_frameworks = obj(
    "frameworks:dev-extension",
    "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
)
dev_host_resources = obj(
    "resources:dev-host",
    "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
)
dev_extension_resources = obj(
    "resources:dev-extension",
    "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
)
embed_file = obj(
    "embed-file:dev-extension",
    f"isa = PBXBuildFile; fileRef = {dev_extension_product}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};",
)
embed_phase = obj(
    "embed:dev-extension",
    f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({embed_file},); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;',
)
dev_host_configs, dev_extension_configs = [], []
for mode in ["Debug", "Release"]:
    for label, settings, output in [
        (
            "dev-host",
            {
                "PRODUCT_NAME": "TokenStatMenuDevWidgetTest",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.tupig.TokenStatMenu.DevWidgetTest",
                "INFOPLIST_FILE": "Resources/DevWidgetHost-Info.plist",
                "CODE_SIGN_ENTITLEMENTS": "Resources/DevWidgetHost.entitlements",
                "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks"',
            },
            dev_host_configs,
        ),
        (
            "dev-extension",
            {
                "PRODUCT_NAME": "TokenStatDevWidgetTest",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.tupig.TokenStatMenu.DevWidgetTest.Widget",
                "INFOPLIST_FILE": "Resources/DevWidgetExtension-Info.plist",
                "CODE_SIGN_ENTITLEMENTS": "Resources/DevWidgetExtension.entitlements",
                "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../../../../Frameworks @executable_path/../Frameworks"',
            },
            dev_extension_configs,
        ),
    ]:
        pairs = [f"{key} = {value};" for key, value in settings.items()]
        pairs += [
            "GENERATE_INFOPLIST_FILE = NO;",
            "CODE_SIGN_STYLE = Manual;",
            'CODE_SIGN_IDENTITY = "-";',
            "ENABLE_APP_SANDBOX = YES;",
            "SWIFT_VERSION = 5.0;",
            "MACOSX_DEPLOYMENT_TARGET = 13.0;",
            "SWIFT_OPTIMIZATION_LEVEL = -Onone;",
            "C51C_PERSONAL_TEAM_ID = UNRESOLVED;",
            "SKIP_INSTALL = NO;",
        ]
        output.append(
            obj(
                "target-config:" + label + ":" + mode,
                f"isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ {' '.join(pairs)} }};",
            )
        )
dev_host_config_list = obj(
    "target-list:dev-host",
    f"isa = XCConfigurationList; buildConfigurations = {refs(dev_host_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;",
)
dev_extension_config_list = obj(
    "target-list:dev-extension",
    f"isa = XCConfigurationList; buildConfigurations = {refs(dev_extension_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;",
)
dev_extension_target = obj(
    "target:dev-extension",
    f"""isa = PBXNativeTarget; buildConfigurationList = {dev_extension_config_list};
    buildPhases = ({dev_extension_sources}, {dev_extension_frameworks}, {dev_extension_resources},); buildRules = (); dependencies = ();
    name = TokenStatDevWidgetTest; productName = TokenStatDevWidgetTest; productReference = {dev_extension_product}; productType = "com.apple.product-type.app-extension";""",
)
proxy = obj(
    "proxy:dev-extension",
    f"isa = PBXContainerItemProxy; containerPortal = {ident('project')}; proxyType = 1; remoteGlobalIDString = {dev_extension_target}; remoteInfo = TokenStatDevWidgetTest;",
)
dependency = obj(
    "dependency:dev-extension",
    f"isa = PBXTargetDependency; target = {dev_extension_target}; targetProxy = {proxy};",
)
dev_host_target = obj(
    "target:dev-host",
    f"""isa = PBXNativeTarget; buildConfigurationList = {dev_host_config_list};
    buildPhases = ({dev_host_sources}, {dev_host_frameworks}, {dev_host_resources}, {embed_phase},); buildRules = (); dependencies = ({dependency},);
    name = TokenStatMenuDevWidgetTest; productName = TokenStatMenuDevWidgetTest; productReference = {dev_host_product}; productType = "com.apple.product-type.application";""",
)

# Hostless XCTest compiles the exact product runner, store and provider files.
# It has no App/appex dependency, entitlements or test host process.
logic_product = obj(
    "product:dev-logic-tests",
    "isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = TokenStatDevWidgetLogicTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;",
)
logic_refs, logic_builds = [], []
for path in sorted((root / "Tests/TokenStatDevWidgetLogicTests").glob("*.swift")):
    key = path.relative_to(root).as_posix()
    ref = obj(
        "file:" + key,
        f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.name}"; sourceTree = "<group>";',
    )
    logic_refs.append(ref)
    logic_builds.append(
        obj("build:dev-logic-tests:" + key, f"isa = PBXBuildFile; fileRef = {ref};")
    )
groups.append(
    obj(
        "group:dev-logic-tests",
        f'isa = PBXGroup; children = {refs(logic_refs)}; path = "Tests/TokenStatDevWidgetLogicTests"; sourceTree = "<group>";',
    )
)
for key, ref in dev_files.items():
    if key.startswith("Sources/TokenStatDevWidgetShared/") or key.endswith(
        "/DevProvider.swift"
    ):
        logic_builds.append(
            obj("build:dev-logic-tests:" + key, f"isa = PBXBuildFile; fileRef = {ref};")
        )
logic_sources = obj(
    "sources:dev-logic-tests",
    f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(logic_builds)}; runOnlyForDeploymentPostprocessing = 0;",
)
xctest = obj(
    "framework:XCTest",
    "isa = PBXFileReference; lastKnownFileType = wrapper.framework; path = Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework; sourceTree = DEVELOPER_DIR;",
)
xctest_build = obj("build:XCTest", f"isa = PBXBuildFile; fileRef = {xctest};")
logic_frameworks = obj(
    "frameworks:dev-logic-tests",
    f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({xctest_build},); runOnlyForDeploymentPostprocessing = 0;",
)
logic_configs = []
for mode in ["Debug", "Release"]:
    logic_configs.append(
        obj(
            "config:dev-logic-tests:" + mode,
            f"""isa = XCBuildConfiguration; name = {mode}; buildSettings = {{
        PRODUCT_NAME = TokenStatDevWidgetLogicTests;
        PRODUCT_BUNDLE_IDENTIFIER = com.tupig.TokenStatMenu.DevWidgetLogicTests;
        MACOSX_DEPLOYMENT_TARGET = 14.0;
        GENERATE_INFOPLIST_FILE = YES;
        SUPPORTED_PLATFORMS = macosx;
        SKIP_INSTALL = YES;
        CODE_SIGNING_ALLOWED = NO;
        CODE_SIGNING_REQUIRED = NO;
        CODE_SIGN_IDENTITY = "";
        ENABLE_APP_SANDBOX = NO;
        ENABLE_HARDENED_RUNTIME = NO;
        TEST_HOST = "";
        BUNDLE_LOADER = "";
        ENABLE_TESTING_SEARCH_PATHS = YES;
        SWIFT_OPTIMIZATION_LEVEL = "-Onone";
        FRAMEWORK_SEARCH_PATHS = ("$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks",);
        LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@loader_path/../Frameworks", "@executable_path/../Frameworks", "$(PLATFORM_DIR)/Developer/Library/Frameworks",);
    }};""",
        )
    )
logic_list = obj(
    "config-list:dev-logic-tests",
    f"isa = XCConfigurationList; buildConfigurations = {refs(logic_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;",
)
logic_target = obj(
    "target:dev-logic-tests",
    f"""isa = PBXNativeTarget; buildConfigurationList = {logic_list};
    buildPhases = ({logic_sources}, {logic_frameworks},); buildRules = (); dependencies = ();
    name = TokenStatDevWidgetLogicTests; productName = TokenStatDevWidgetLogicTests; productReference = {logic_product}; productType = "com.apple.product-type.bundle.unit-test";""",
)
objects[products] = (
    f'isa = PBXGroup; children = ({product}, {widget_extension_product}, {dev_host_product}, {dev_extension_product}, {logic_product},); name = Products; sourceTree = "<group>";'
)
objects[main] = (
    f'isa = PBXGroup; children = {refs(groups + resource_files + [xctest, products])}; sourceTree = "<group>";'
)


# Production widget extension: built as an appex and embedded into the app's
# Contents/PlugIns, so one install surface carries the menu bar and the widget.
def widget_phase_sources():
    build_files = []
    for folder in ["TokenStatWidgetShared", "TokenStatWidgetExtension"]:
        for path in sorted((root / "Sources" / folder).glob("*.swift")):
            key = path.relative_to(root).as_posix()
            build_files.append(
                obj(
                    "build:widget:" + key,
                    f"isa = PBXBuildFile; fileRef = {widget_files[key]};",
                )
            )
    return obj(
        "sources:widget",
        f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(build_files)}; runOnlyForDeploymentPostprocessing = 0;",
    )


widget_sources = widget_phase_sources()
widget_frameworks = obj(
    "frameworks:widget",
    "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
)
widget_resources_phase = obj(
    "resources:widget",
    "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
)
widget_configs = []
for mode in ["Debug", "Release"]:
    optimization = "-Onone" if mode == "Debug" else "-O"
    widget_configs.append(
        obj(
            "target-config:widget:" + mode,
            f'''isa = XCBuildConfiguration; name = {mode}; buildSettings = {{
        PRODUCT_NAME = TokenStatMenuWidget;
        PRODUCT_BUNDLE_IDENTIFIER = com.tupig.TokenStatMenu.Widget;
        INFOPLIST_FILE = Resources/WidgetExtension-Info.plist;
        GENERATE_INFOPLIST_FILE = NO;
        CODE_SIGN_ENTITLEMENTS = Resources/WidgetExtension.entitlements;
        CODE_SIGN_IDENTITY = "-";
        CODE_SIGN_STYLE = Manual;
        ENABLE_APP_SANDBOX = YES;
        ENABLE_HARDENED_RUNTIME = YES;
        SWIFT_VERSION = 5.0;
        MACOSX_DEPLOYMENT_TARGET = 13.0;
        SWIFT_OPTIMIZATION_LEVEL = "{optimization}";
        SKIP_INSTALL = YES;
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../../../../Frameworks @executable_path/../Frameworks";
        TOKENSTAT_WIDGET_GROUP = "";
    }};''',
        )
    )
widget_config_list = obj(
    "target-list:widget",
    f"isa = XCConfigurationList; buildConfigurations = {refs(widget_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;",
)
widget_target = obj(
    "target:widget",
    f"""isa = PBXNativeTarget; buildConfigurationList = {widget_config_list};
    buildPhases = ({widget_sources}, {widget_frameworks}, {widget_resources_phase},); buildRules = (); dependencies = ();
    name = TokenStatMenuWidget; productName = TokenStatMenuWidget; productReference = {widget_extension_product}; productType = "com.apple.product-type.app-extension";""",
)
widget_proxy = obj(
    "proxy:widget",
    f"isa = PBXContainerItemProxy; containerPortal = {ident('project')}; proxyType = 1; remoteGlobalIDString = {widget_target}; remoteInfo = TokenStatMenuWidget;",
)
widget_dependency = obj(
    "dependency:widget",
    f"isa = PBXTargetDependency; target = {widget_target}; targetProxy = {widget_proxy};",
)
widget_embed_file = obj(
    "embed-file:widget",
    f"isa = PBXBuildFile; fileRef = {widget_extension_product}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};",
)
widget_embed_phase = obj(
    "embed:widget",
    f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({widget_embed_file},); name = "Embed Foundation Extensions"; runOnlyForDeploymentPostprocessing = 0;',
)
# The app target owns the embed phase and depends on the extension target.
objects[target] = f"""isa = PBXNativeTarget; buildConfigurationList = {target_list};
    buildPhases = ({source_phase}, {framework_phase}, {resource_phase}, {widget_embed_phase},); buildRules = (); dependencies = ({widget_dependency},);
    name = TokenStatMenu; productName = TokenStatMenu; productReference = {product}; productType = "com.apple.product-type.application";"""

project = obj(
    "project",
    f"""isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }};
    buildConfigurationList = {project_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en;
    hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hans",);
    mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target}, {widget_target}, {dev_host_target}, {dev_extension_target}, {logic_target},);""",
)
directory = root / "TokenStatMenu.xcodeproj"
directory.mkdir(exist_ok=True)
text = "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"
text += "\n".join(f"{key} = {{ {value} }};" for key, value in objects.items())
text += f"\n}}; rootObject = {project}; }}\n"
(directory / "project.pbxproj").write_text(text)
# Bind the app target explicitly. Relying on an inferred user scheme caused
# Xcode's destination preflight to report an empty supported-platform set.
scheme_directory = directory / "xcshareddata" / "xcschemes"
scheme_directory.mkdir(parents=True, exist_ok=True)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TokenStatMenu.app" BlueprintName="TokenStatMenu" ReferencedContainer="container:TokenStatMenu.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TokenStatMenu.app" BlueprintName="TokenStatMenu" ReferencedContainer="container:TokenStatMenu.xcodeproj"/>
    </BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(scheme_directory / "TokenStatMenu.xcscheme").write_text(scheme)
dev_scheme = (
    scheme.replace("TokenStatMenu.app", "TokenStatMenuDevWidgetTest.app")
    .replace(
        'BlueprintName="TokenStatMenu"', 'BlueprintName="TokenStatMenuDevWidgetTest"'
    )
    .replace(
        f'BlueprintIdentifier="{target}"', f'BlueprintIdentifier="{dev_host_target}"'
    )
)
(scheme_directory / "TokenStatMenuDevWidgetTest.xcscheme").write_text(dev_scheme)
logic_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{logic_target}" BuildableName="TokenStatDevWidgetLogicTests.xctest" BlueprintName="TokenStatDevWidgetLogicTests" ReferencedContainer="container:TokenStatMenu.xcodeproj"/>'
logic_scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
        {logic_reference}
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO">
    <Testables>
      <TestableReference skipped="NO">{logic_reference}</TestableReference>
    </Testables>
  </TestAction>
  <AnalyzeAction buildConfiguration="Debug"/>
</Scheme>
"""
(scheme_directory / "TokenStatDevWidgetLogicTests.xcscheme").write_text(logic_scheme)
# The widget extension is run through its own scheme. It is still embedded in
# the app bundle, so building the app is what actually ships it.
widget_scheme = (
    scheme.replace("TokenStatMenu.app", "TokenStatMenuWidget.appex")
    .replace('BlueprintName="TokenStatMenu"', 'BlueprintName="TokenStatMenuWidget"')
    .replace(
        f'BlueprintIdentifier="{target}"', f'BlueprintIdentifier="{widget_target}"'
    )
)
(scheme_directory / "TokenStatMenuWidget.xcscheme").write_text(widget_scheme)
print(directory)
print(
    "targets: TokenStatMenu, TokenStatMenuWidget, TokenStatMenuDevWidgetTest, TokenStatDevWidgetTest, TokenStatDevWidgetLogicTests"
)
