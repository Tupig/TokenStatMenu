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
for folder in ["TokenStatCore", "TokenStatMenu"]:
    files = []
    for path in sorted((root / "Sources" / folder).glob("*.swift")):
        key = path.relative_to(root).as_posix()
        ref = obj("file:" + key, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.name}"; sourceTree = "<group>";')
        files.append(ref)
        sources.append(obj("build:" + key, f"isa = PBXBuildFile; fileRef = {ref};"))
    groups.append(obj("group:" + folder, f'isa = PBXGroup; children = {refs(files)}; path = "Sources/{folder}"; sourceTree = "<group>";'))
product = obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = TokenStatMenu.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj("products", f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
resource_files = [obj("resource:" + n, f'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/{n}"; sourceTree = "<group>";') for n in ["Info.plist", "config.example.plist"]]
main = obj("main", f'isa = PBXGroup; children = {refs(groups + resource_files + [products])}; sourceTree = "<group>";')
source_phase = obj("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(sources)}; runOnlyForDeploymentPostprocessing = 0;")
framework_phase = obj("frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
resource_phase = obj("resources", "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
project_configs, target_configs = [], []
for mode in ["Debug", "Release"]:
    project_configs.append(obj("project-config:" + mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ MACOSX_DEPLOYMENT_TARGET = 13.0; SDKROOT = macosx; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }};'))
    optimization = "-Onone" if mode == "Debug" else "-O"
    target_configs.append(obj("target-config:" + mode, f'''isa = XCBuildConfiguration; name = {mode}; buildSettings = {{
        PRODUCT_NAME = TokenStatMenu;
        PRODUCT_BUNDLE_IDENTIFIER = com.tupig.TokenStatMenu;
        INFOPLIST_FILE = Resources/Info.plist;
        GENERATE_INFOPLIST_FILE = NO;
        CODE_SIGN_IDENTITY = "-";
        CODE_SIGN_STYLE = Manual;
        ENABLE_APP_SANDBOX = NO;
        ENABLE_HARDENED_RUNTIME = YES;
        SWIFT_OPTIMIZATION_LEVEL = "{optimization}";
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
    }};'''))
project_list = obj("project-list", f"isa = XCConfigurationList; buildConfigurations = {refs(project_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
target_list = obj("target-list", f"isa = XCConfigurationList; buildConfigurations = {refs(target_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
target = obj("target", f'''isa = PBXNativeTarget; buildConfigurationList = {target_list};
    buildPhases = ({source_phase}, {framework_phase}, {resource_phase},); buildRules = (); dependencies = ();
    name = TokenStatMenu; productName = TokenStatMenu; productReference = {product}; productType = "com.apple.product-type.application";''')
project = obj("project", f'''isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }};
    buildConfigurationList = {project_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en;
    hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hans",);
    mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);''')
directory = root / "TokenStatMenu.xcodeproj"
directory.mkdir(exist_ok=True)
text = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
text += "\n".join(f"{key} = {{ {value} }};" for key, value in objects.items())
text += f"\n}}; rootObject = {project}; }}\n"
(directory / "project.pbxproj").write_text(text)
print(directory)
