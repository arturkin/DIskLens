import Foundation
import DiskLensCore

// Privileged scanner CLI. Real implementation lands in M7 (admin scan):
// parse --root/--out/--progress args, run the shared Scanner as root, and write
// a TreeCodec blob to --out plus periodic progress JSON to --progress.
FileHandle.standardError.write(Data("disklens-helper: not yet implemented\n".utf8))
exit(0)
