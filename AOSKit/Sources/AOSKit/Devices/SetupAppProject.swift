import Foundation

/// The small iPhone app the person builds once in Xcode (Settings > Apps, "Set Up Step by Step"): with automatic
/// signing Xcode then registers the iPhone with the team, creates the development certificate if there is none, and
/// creates the profile; with a wildcard App ID of the team (`<prefix>.*`) that profile is a wildcard Xcode keeps up
/// to date, and it signs every app under the prefix. aOS never runs Xcode's signing itself (Docs/DESIGN.md).
///
/// The project was made with XcodeGen (iOS 17, SwiftUI, generated Info.plist, automatic signing); the bundle id and
/// the team go in when it is written.
public enum SetupAppProject {
    public static let name = "aOS Setup"

    /// Writes the project into `folder` (replacing an earlier one) and returns the .xcodeproj.
    public static func write(to folder: URL, bundleID: String, team: String, title: String, message: String) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        let project = folder.appendingPathComponent("\(name).xcodeproj")
        try fm.createDirectory(at: project.appendingPathComponent("project.xcworkspace"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let pbxproj = template
            .replacingOccurrences(of: "AOSBUNDLEID", with: bundleID)
            .replacingOccurrences(of: "AOSTEAM", with: team)
        try pbxproj.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        try workspace.write(to: project.appendingPathComponent("project.xcworkspace/contents.xcworkspacedata"),
                            atomically: true, encoding: .utf8)
        try source(title: title, message: message)
            .write(to: folder.appendingPathComponent("Sources/SetupApp.swift"), atomically: true, encoding: .utf8)
        return project
    }

    static func source(title: String, message: String) -> String {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
        import SwiftUI

        @main
        struct SetupApp: App {
            var body: some Scene {
                WindowGroup {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(.green)
                        Text(\(literal(title))).font(.title.bold())
                        Text(\(literal(message)))
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .padding(32)
                }
            }
        }

        """
    }

    static let workspace = #"""
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""#

    static let template = #"""
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
		5D787594E0743B04D67EB977 /* SetupApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = E2A4D00469E884351E9108FC /* SetupApp.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		E2A4D00469E884351E9108FC /* SetupApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SetupApp.swift; sourceTree = "<group>"; };
		F1AE356C86709B8412CC79AA /* aOS Setup.app */ = {isa = PBXFileReference; includeInIndex = 0; lastKnownFileType = wrapper.application; path = "aOS Setup.app"; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		3249561C1C7A18929CC4C146 /* Sources */ = {
			isa = PBXGroup;
			children = (
				E2A4D00469E884351E9108FC /* SetupApp.swift */,
			);
			path = Sources;
			sourceTree = "<group>";
		};
		58381B84B691190FD1715022 = {
			isa = PBXGroup;
			children = (
				3249561C1C7A18929CC4C146 /* Sources */,
				D15337C0D6A7707D523134FD /* Products */,
			);
			sourceTree = "<group>";
		};
		D15337C0D6A7707D523134FD /* Products */ = {
			isa = PBXGroup;
			children = (
				F1AE356C86709B8412CC79AA /* aOS Setup.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		9D4EBE7756E228D18FC6F0E7 /* aOS Setup */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 22851AE7332400E76F78FADE /* Build configuration list for PBXNativeTarget "aOS Setup" */;
			buildPhases = (
				6F0D7446D5FE323A3A6AF04B /* Sources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = "aOS Setup";
			packageProductDependencies = (
			);
			productName = "aOS Setup";
			productReference = F1AE356C86709B8412CC79AA /* aOS Setup.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		2645C7243801E98F554265FE /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = YES;
				LastUpgradeCheck = 1430;
				TargetAttributes = {
					9D4EBE7756E228D18FC6F0E7 = {
						DevelopmentTeam = AOSTEAM;
						ProvisioningStyle = Automatic;
					};
				};
			};
			buildConfigurationList = 9D445C45CB7729E7EF1CB853 /* Build configuration list for PBXProject "aOS Setup" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				Base,
				en,
			);
			mainGroup = 58381B84B691190FD1715022;
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = D15337C0D6A7707D523134FD /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				9D4EBE7756E228D18FC6F0E7 /* aOS Setup */,
			);
		};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		6F0D7446D5FE323A3A6AF04B /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				5D787594E0743B04D67EB977 /* SetupApp.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		0E34811CAE7EA65346B02829 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++14";
				CLANG_CXX_LIBRARY = "libc++";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				CODE_SIGN_STYLE = Automatic;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				DEVELOPMENT_TEAM = AOSTEAM;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"$(inherited)",
					"DEBUG=1",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		68EE64E4A5F11C9AE57E3F7B /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_IDENTITY = "iPhone Developer";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "aOS Setup";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = AOSBUNDLEID;
				PRODUCT_NAME = "aOS Setup";
				SDKROOT = iphoneos;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Debug;
		};
		AAD4487C9E9B10D1B04E0A63 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++14";
				CLANG_CXX_LIBRARY = "libc++";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				CODE_SIGN_STYLE = Automatic;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				DEVELOPMENT_TEAM = AOSTEAM;
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		AAD6CED56F5350ECA9CBCFA7 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_IDENTITY = "iPhone Developer";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "aOS Setup";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = AOSBUNDLEID;
				PRODUCT_NAME = "aOS Setup";
				SDKROOT = iphoneos;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		22851AE7332400E76F78FADE /* Build configuration list for PBXNativeTarget "aOS Setup" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				68EE64E4A5F11C9AE57E3F7B /* Debug */,
				AAD6CED56F5350ECA9CBCFA7 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		};
		9D445C45CB7729E7EF1CB853 /* Build configuration list for PBXProject "aOS Setup" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				0E34811CAE7EA65346B02829 /* Debug */,
				AAD4487C9E9B10D1B04E0A63 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		};
/* End XCConfigurationList section */
	};
	rootObject = 2645C7243801E98F554265FE /* Project object */;
}
"""#
}
