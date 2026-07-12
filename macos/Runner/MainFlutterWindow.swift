import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Match the recorder's phone-like layout on first launch while keeping the
    // native macOS window fully resizable.
    self.contentMinSize = NSSize(width: 520, height: 720)
    self.setContentSize(NSSize(width: 625, height: 1000))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
