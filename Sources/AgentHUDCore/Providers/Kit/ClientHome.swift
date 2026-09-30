import AgentHUDSupport
import Foundation

/// The client home dimension: one client can run from several data directories with different sign-ins.
public enum ClientHome {
    /// Empty for the client's default directory, otherwise a hash of the resolved path.
    public static func key(_ directory: URL, defaultDirectory: URL) -> String {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return path == defaultDirectory.standardizedFileURL.resolvingSymlinksInPath().path ? "" : RecordCoding.hash([path])
    }
}
