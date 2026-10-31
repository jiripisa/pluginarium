import CRenderCore
import PluginariumCore

/// Audio Unit hosting and audio engine. Placeholder; later tasks replace it.
public enum PluginariumAudio {

    /// Version of the C render core this module is linked against.
    public static var renderCoreVersion: Int {
        Int(crendercore_version())
    }
}
