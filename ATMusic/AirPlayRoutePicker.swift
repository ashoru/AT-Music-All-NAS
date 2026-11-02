import SwiftUI
import AVKit

/// Apple 原生 AirPlay 音频路由选择器组件
/// 调用系统级 AVRoutePickerView，直接无缝呼出隔空播放（AirPlay）面板，
/// 支持流转至 HomePod、Apple TV、AirPods 及蓝牙音响设备，与 Apple Music 原生体验完全一致。
struct AirPlayRoutePicker: UIViewRepresentable {
    var tintColor: UIColor
    var activeTintColor: UIColor

    init(
        tintColor: UIColor = .white.withAlphaComponent(0.85),
        activeTintColor: UIColor = UIColor(Color.atmusicAmber)
    ) {
        self.tintColor = tintColor
        self.activeTintColor = activeTintColor
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.backgroundColor = .clear
        routePicker.tintColor = tintColor
        routePicker.activeTintColor = activeTintColor
        routePicker.prioritizesVideoDevices = false
        return routePicker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}
