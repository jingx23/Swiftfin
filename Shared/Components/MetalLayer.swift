//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import QuartzCore

#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Workaround for MoltenVK that sets the drawableSize to 1x1 to forcefully complete
// the presentation, this causes flicker and the drawableSize possibly staying at 1x1
// https://github.com/mpv-player/mpv/pull/13651

@MainActor
class MetalLayer: CAMetalLayer {

    override nonisolated(unsafe) init() {
        super.init()
    }

    required nonisolated(unsafe) init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override nonisolated(unsafe) init(layer: Any) {
        super.init(layer: layer)
    }

    override nonisolated(unsafe) var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
