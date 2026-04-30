import Foundation

func zoomItDebugLog(_ message: String) {
    fputs("[ZoomIt] \(message)\n", stderr)
    fflush(stderr)
}

