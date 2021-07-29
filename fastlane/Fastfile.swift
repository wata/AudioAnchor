// This file contains the fastlane.tools configuration
// You can find the documentation at https://docs.fastlane.tools
//
// For a list of all available actions, check out
//
//     https://docs.fastlane.tools/actions
//

import Foundation

class Fastfile: LaneFile {
    let repositoryName = environmentVariable(get: "GITHUB_REPOSITORY")
    let binaryFileName = environmentVariable(get: "BINARY_FILE_NAME")
    let newVersion = environmentVariable(get: "NEW_VERSION")
    let outputDirectory = "dist"
    let appcastFileName = "appcast.xml"

    func releaseLane() {
        desc("Build and release a new version of this macOS app")

        // Bump the version in the Info.plist
        incrementVersionNumber(versionNumber: .userDefined(newVersion))
        incrementBuildNumber()

        // From git commits, get the latest changes
        let changelog = changelogFromGitCommits()

        // Build the app
        buildMacApp(
            outputDirectory: outputDirectory,
            exportMethod: "development"
        )

        // Generate the Sparkle app cast for this new version
        let assetPath = updateAppcast()

        // Commit all of the files we changed
        commitVersionBump(
            message: "Version bump to \(getVersionNumber())",
            xcodeproj: "\(binaryFileName).xcodeproj",
            include: [appcastFileName]
        )

        // Make a tag for this release
        addGitTag(tag: .userDefined(newVersion))

        // Push to remote
        pushToGitRemote()

        // Push GitHub Release
        setGithubRelease(repositoryName: repositoryName,
                         tagName: newVersion,
                         name: .userDefined(newVersion),
                         description: .userDefined(changelog),
                         uploadAssets: .userDefined([assetPath]))
    }
}

extension Fastfile {
    private func updateAppcast() -> String {
        // Set up a formatted file name for the app name, and an escaped variant
        let formattedAppName = binaryFileName.replacingOccurrences(of: " ", with: "-")
        let escapedAppName = binaryFileName.replacingOccurrences(of: " ", with: "\\ ")
        let archiveName = "\(formattedAppName)-\(newVersion).zip"
        let source = "\(outputDirectory)/\(escapedAppName).app"
        let dest = "\(outputDirectory)/\(archiveName)"

        // Generate the final ZIP for the build
        sh(command: "ditto -c -k --sequesterRsrc --keepParent \(source) \(dest)", log: false)

        let downloadURLPrefix = "https://github.com/\(repositoryName)/releases/download/\(newVersion)/"
        sh(command: "./bin/generate_appcast --download-url-prefix \(downloadURLPrefix) -o \(appcastFileName) \(outputDirectory)", log: false)

        return dest
    }
}
