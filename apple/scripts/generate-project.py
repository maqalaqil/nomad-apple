#!/usr/bin/env python3
"""Generate the iPhone, iPad, and native Mac project without an external generator."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--team-id", help="Apple development team; stored only in the ignored generated project")
parser.add_argument("--bundle-id", help="Use the registered bundle identifier for this installation")
args = parser.parse_args()
if args.team_id and not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
    parser.error("--team-id must contain 10 uppercase letters or digits")
if args.bundle_id and not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_id):
    parser.error("--bundle-id must be a reverse-DNS identifier")

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "NomadApple.xcodeproj"
PROJECT.mkdir(exist_ok=True)

def ident(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def quoted(value):
    return json.dumps(str(value))

# Keep the user's Xcode signing selection when regenerating after new sources.
personal_settings = {}
existing_project = PROJECT / "project.pbxproj"
legacy_project = ROOT / "NomadPad.xcodeproj/project.pbxproj"
if not existing_project.exists() and legacy_project.exists():
    existing_project = legacy_project
if existing_project.exists():
    try:
        previous = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(existing_project)]))
        previous_settings = previous["objects"][ident("target-Debug")]["buildSettings"]
        for key in ["DEVELOPMENT_TEAM", "PRODUCT_BUNDLE_IDENTIFIER"]:
            if isinstance(previous_settings.get(key), str) and previous_settings[key]:
                personal_settings[key] = previous_settings[key]
    except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError):
        raise SystemExit("Existing Xcode settings could not be read. Project generation stopped to preserve signing choices.")
if args.team_id:
    personal_settings["DEVELOPMENT_TEAM"] = args.team_id
if args.bundle_id:
    personal_settings["PRODUCT_BUNDLE_IDENTIFIER"] = args.bundle_id

objects = []
def add(key, contents):
    objects.append(f"\t\t{ident(key)} = {{ {contents} }};")

sources = sorted(list((ROOT / "App").rglob("*.swift")) + list((ROOT / "App").rglob("*.mm")) + list((ROOT / "Sources/NomadCore").rglob("*.swift")))
source_refs, source_builds = [], []
for path in sources:
    relative = path.relative_to(ROOT).as_posix()
    ref, build = "ref:" + relative, "build:" + relative
    file_type = "sourcecode.cpp.objcpp" if path.suffix == ".mm" else "sourcecode.swift"
    add(ref, f"isa = PBXFileReference; lastKnownFileType = {file_type}; path = {quoted(relative)}; sourceTree = SOURCE_ROOT;")
    add(build, f"isa = PBXBuildFile; fileRef = {ident(ref)};")
    source_refs.append(ident(ref)); source_builds.append(ident(build))

test_refs, test_builds = [], []
for path in sorted((ROOT / "UITests").glob("*.swift")):
    relative = path.relative_to(ROOT).as_posix()
    ref, build = "ref:" + relative, "build:" + relative
    add(ref, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = SOURCE_ROOT;")
    add(build, f"isa = PBXBuildFile; fileRef = {ident(ref)};")
    test_refs.append(ident(ref)); test_builds.append(ident(build))

add("sqlite-ref", "isa = PBXFileReference; lastKnownFileType = sourcecode.text-based-dylib-definition; name = libsqlite3.tbd; path = usr/lib/libsqlite3.tbd; sourceTree = SDKROOT;")
add("sqlite-build", f"isa = PBXBuildFile; fileRef = {ident('sqlite-ref')};")
add("kiwix-ref", "isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = Vendor/CoreKiwix.xcframework; sourceTree = SOURCE_ROOT;")
add("kiwix-build", f"isa = PBXBuildFile; fileRef = {ident('kiwix-ref')};")
add("resources-ref", "isa = PBXFileReference; lastKnownFileType = folder; path = Resources/WebTools; sourceTree = SOURCE_ROOT;")
add("resources-build", f"isa = PBXBuildFile; fileRef = {ident('resources-ref')};")
add("catalogs-ref", "isa = PBXFileReference; lastKnownFileType = folder; path = Resources/Catalogs; sourceTree = SOURCE_ROOT;")
add("catalogs-build", f"isa = PBXBuildFile; fileRef = {ident('catalogs-ref')};")
for folder in ["SampleLibrary", "ThirdPartyLicenses"]:
    add(folder + "-ref", f"isa = PBXFileReference; lastKnownFileType = folder; path = Resources/{folder}; sourceTree = SOURCE_ROOT;")
    add(folder + "-build", f"isa = PBXBuildFile; fileRef = {ident(folder + '-ref')};")
add("assets-ref", "isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Resources/Assets.xcassets; sourceTree = SOURCE_ROOT;")
add("assets-build", f"isa = PBXBuildFile; fileRef = {ident('assets-ref')};")
add("privacy-ref", "isa = PBXFileReference; lastKnownFileType = text.xml; path = App/Platform/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT;")
add("privacy-build", f"isa = PBXBuildFile; fileRef = {ident('privacy-ref')};")
add("policy-ref", "isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = ../docs/PRIVACY_POLICY.md; sourceTree = SOURCE_ROOT;")
add("policy-build", f"isa = PBXBuildFile; fileRef = {ident('policy-ref')};")
add("product", "isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = NomadApple.app; sourceTree = BUILT_PRODUCTS_DIR;")
add("test-product", "isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = NomadAppleUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;")
add("products", f"isa = PBXGroup; children = ({ident('product')},{ident('test-product')},); name = Products; sourceTree = \"<group>\";")
children = source_refs + test_refs + [ident("SampleLibrary-ref"), ident("ThirdPartyLicenses-ref"), ident("resources-ref"), ident("catalogs-ref"), ident("assets-ref"), ident("privacy-ref"), ident("policy-ref"), ident("sqlite-ref"), ident("kiwix-ref"), ident("products")]
add("main-group", f"isa = PBXGroup; children = ({','.join(children)},); sourceTree = \"<group>\";")
add("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(source_builds)},); runOnlyForDeploymentPostprocessing = 0;")
add("frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({ident('sqlite-build')},{ident('kiwix-build')},); runOnlyForDeploymentPostprocessing = 0;")
add("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ident('SampleLibrary-build')},{ident('ThirdPartyLicenses-build')},{ident('resources-build')},{ident('catalogs-build')},{ident('assets-build')},{ident('privacy-build')},{ident('policy-build')},); runOnlyForDeploymentPostprocessing = 0;")
add("test-sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(test_builds)},); runOnlyForDeploymentPostprocessing = 0;")
add("test-frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
embed_llama = '''set -eu
case "$PLATFORM_NAME" in
    iphoneos) slice="ios-arm64" ;;
    macosx) slice="macos-arm64_x86_64" ;;
    *) exit 0 ;;
esac
framework="$PROJECT_DIR/Vendor/build-apple/llama.xcframework/$slice/llama.framework"
destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$destination"
/usr/bin/ditto "$framework" "$destination/llama.framework"
# Preserve the vendor's matching symbols for archive validation and crash reports.
symbols="$PROJECT_DIR/Vendor/build-apple/llama.xcframework/$slice/dSYMs/llama.dSYM"
if [ "$ACTION" = "install" ] && [ -d "$symbols" ]; then
    mkdir -p "$DWARF_DSYM_FOLDER_PATH"
    /usr/bin/ditto "$symbols" "$DWARF_DSYM_FOLDER_PATH/llama.dSYM"
fi
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements "$destination/llama.framework"
fi
'''
add("embed-llama", f"isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); name = \"Embed local inference framework\"; shellPath = /bin/sh; shellScript = {quoted(embed_llama)}; runOnlyForDeploymentPostprocessing = 0; alwaysOutOfDate = 1;")
project_settings = {
    "SDKROOT": "auto", "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "MACOSX_DEPLOYMENT_TARGET": "26.0", "SWIFT_VERSION": "5.0",
    "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "SWIFT_STRICT_CONCURRENCY": "targeted", "ENABLE_BITCODE": "NO",
}
target_settings = {
    "PRODUCT_BUNDLE_IDENTIFIER": "io.github.maqalaqil.nomadpad", "PRODUCT_NAME": "$(TARGET_NAME)",
    "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_KEY_CFBundleDisplayName": "NOMAD Apple",
    # One workspace per process prevents independent windows from racing manifest saves.
    "INFOPLIST_FILE[sdk=iphone*]": "App/Platform/NomadApple-iOS.plist",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "NO", "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "INFOPLIST_KEY_NSFaceIDUsageDescription": "Unlock your offline password vault.",
    "INFOPLIST_KEY_NSCameraUsageDescription": "Record video locally with the camera tool you open.",
    "INFOPLIST_KEY_NSMicrophoneUsageDescription": "Record audio locally with the recording tool you open.",
    "INFOPLIST_KEY_UIFileSharingEnabled": "YES", "INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace": "YES",
    "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
    "SUPPORTS_MACCATALYST": "NO", "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "App/Platform/NomadApple-macOS.entitlements",
    "ENABLE_APP_SANDBOX[sdk=macosx*]": "YES",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "INFOPLIST_KEY_LSApplicationCategoryType[sdk=macosx*]": "public.app-category.reference",
    "INFOPLIST_KEY_NSHumanReadableCopyright[sdk=macosx*]": "Copyright © 2026 NOMAD Apple contributors. Third-party works retain their respective copyrights.",
    "SKIP_INSTALL": "NO",
    "CURRENT_PROJECT_VERSION": "9", "MARKETING_VERSION": "1.0",
    "SWIFT_OBJC_BRIDGING_HEADER": "$(PROJECT_DIR)/App/Library/NomadZIM-Bridging-Header.h",
    "CLANG_CXX_LANGUAGE_STANDARD": "c++17", "OTHER_LDFLAGS": "$(inherited) -lc++ -lz -liconv",
    "HEADER_SEARCH_PATHS[sdk=iphoneos*]": "$(inherited) $(PROJECT_DIR)/Vendor/CoreKiwix.xcframework/ios-arm64/Headers",
    "HEADER_SEARCH_PATHS[sdk=iphonesimulator*]": "$(inherited) $(PROJECT_DIR)/Vendor/CoreKiwix.xcframework/ios-arm64_x86_64-simulator/Headers",
    "HEADER_SEARCH_PATHS[sdk=macosx*]": "$(inherited) $(PROJECT_DIR)/Vendor/CoreKiwix.xcframework/macos-arm64_x86_64/Headers",
    "FRAMEWORK_SEARCH_PATHS[sdk=macosx*]": "$(inherited) $(PROJECT_DIR)/Vendor/build-apple/llama.xcframework/macos-arm64_x86_64",
    "FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]": "$(inherited) $(PROJECT_DIR)/Vendor/build-apple/llama.xcframework/ios-arm64",
    "OTHER_LDFLAGS[sdk=iphoneos*]": "$(inherited) -lc++ -lz -liconv -framework llama",
    "OTHER_LDFLAGS[sdk=macosx*]": "$(inherited) -lc++ -lz -liconv -framework llama",
    "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]": "$(inherited) @executable_path/../Frameworks",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
}
target_settings.update(personal_settings)
test_settings = {
    "PRODUCT_BUNDLE_IDENTIFIER": target_settings["PRODUCT_BUNDLE_IDENTIFIER"] + ".uitests", "PRODUCT_NAME": "$(TARGET_NAME)",
    "GENERATE_INFOPLIST_FILE": "YES", "TARGETED_DEVICE_FAMILY": "1,2", "TEST_TARGET_NAME": "NomadApple",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx", "CODE_SIGN_STYLE": "Automatic",
}
if "DEVELOPMENT_TEAM" in personal_settings:
    test_settings["DEVELOPMENT_TEAM"] = personal_settings["DEVELOPMENT_TEAM"]
for level, settings in [("project", project_settings), ("target", target_settings), ("test", test_settings)]:
    configurations = []
    for configuration in ["Debug", "Release"]:
        values = dict(settings)
        values["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if configuration == "Debug" else "-O"
        values["DEBUG_INFORMATION_FORMAT"] = "dwarf" if configuration == "Debug" else "dwarf-with-dsym"
        if configuration == "Debug": values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        key = f"{level}-{configuration}"
        body = " ".join(f"{quoted(k)} = {quoted(v)};" for k, v in values.items())
        add(key, f"isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {configuration};")
        configurations.append(ident(key))
    add(level + "-configurations", f"isa = XCConfigurationList; buildConfigurations = ({','.join(configurations)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
add("target", f"isa = PBXNativeTarget; buildConfigurationList = {ident('target-configurations')}; buildPhases = ({ident('sources')},{ident('frameworks')},{ident('resources')},{ident('embed-llama')},); buildRules = (); dependencies = (); name = NomadApple; productName = NomadApple; productReference = {ident('product')}; productType = \"com.apple.product-type.application\";")
add("test-proxy", f"isa = PBXContainerItemProxy; containerPortal = {ident('project')}; proxyType = 1; remoteGlobalIDString = {ident('target')}; remoteInfo = NomadApple;")
add("test-dependency", f"isa = PBXTargetDependency; target = {ident('target')}; targetProxy = {ident('test-proxy')};")
add("test-target", f"isa = PBXNativeTarget; buildConfigurationList = {ident('test-configurations')}; buildPhases = ({ident('test-sources')},{ident('test-frameworks')},); buildRules = (); dependencies = ({ident('test-dependency')},); name = NomadAppleUITests; productName = NomadAppleUITests; productReference = {ident('test-product')}; productType = \"com.apple.product-type.bundle.ui-testing\";")
add("project", f"isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }}; buildConfigurationList = {ident('project-configurations')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {ident('main-group')}; productRefGroup = {ident('products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({ident('target')},{ident('test-target')},);")
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {ident('project')};\n}}\n")
schemes = PROJECT / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="NomadApple.app" BlueprintName="NomadApple" ReferencedContainer="container:NomadApple.xcodeproj"/>'
test_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("test-target")}" BuildableName="NomadAppleUITests.xctest" BlueprintName="NomadAppleUITests" ReferencedContainer="container:NomadApple.xcodeproj"/>'
(schemes / "NomadApple.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_reference}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {PROJECT.name} with {len(sources)} Swift source files")
