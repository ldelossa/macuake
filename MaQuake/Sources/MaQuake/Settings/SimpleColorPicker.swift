import SwiftUI

/// A tab-free picker with independently bound RGB and background opacity.
@MainActor
struct SimpleColorPicker: View {
    let title: String
    @Binding var selection: Color
    @Binding var opacity: Double
    var isParentVisible = true
    var onPresentationChange: @MainActor (UUID, Bool) -> Void = { _, _ in }
    @State private var isPresented = false
    @State private var presentationID = UUID()

    private var presentation: Binding<Bool> {
        Binding(get: { isPresented }, set: { setPresented($0, origin: "popoverBinding") })
    }

    var body: some View {
        Button { setPresented(!isPresented, origin: "swatchButton") } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(selection.opacity(opacity))
                .frame(width: 32, height: 22)
                .background {
                    TransparencyCheckerboard()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue("\(selection.toHex()), \(Int((opacity * 100).rounded()))% opacity")
        .help("Choose \(title.lowercased())")
        .popover(isPresented: presentation, arrowEdge: .bottom) {
            ColorSelectionPopover(title: title, selection: $selection, opacity: $opacity)
        }
        .onChange(of: isParentVisible) {
            AutoHideTrace.record("picker.parentVisibilityChanged", details: "picker=\(title) id=\(presentationID.uuidString.prefix(8)) visible=\(isParentVisible)")
            if !isParentVisible { setPresented(false, origin: "parentHidden") }
        }
        .onDisappear {
            AutoHideTrace.record("picker.presenter.disappeared", details: "picker=\(title) id=\(presentationID.uuidString.prefix(8))", includeWindows: true)
            setPresented(false, origin: "presenterDisappeared")
        }
    }

    private func setPresented(_ presented: Bool, origin: String) {
        let details = "picker=\(title) id=\(presentationID.uuidString.prefix(8)) origin=\(origin) presented=\(presented) wasPresented=\(isPresented) parentVisible=\(isParentVisible)"
        AutoHideTrace.record("picker.presentation.requested", details: details, includeWindows: true)
        guard presented != isPresented, !presented || isParentVisible else {
            AutoHideTrace.record("picker.presentation.ignored", details: details)
            return
        }
        // Acquire protection before AppKit can transfer key focus to the popover.
        onPresentationChange(presentationID, presented)
        AutoHideTrace.record("picker.presentation.callbackReturned", details: details)
        isPresented = presented
        AutoHideTrace.record("picker.presentation.committed", details: details)
    }
}

private struct TransparencyCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 5
            for row in 0..<Int((size.height / cell).rounded(.up)) {
                for column in 0..<Int((size.width / cell).rounded(.up)) {
                    let color = (row + column).isMultiple(of: 2)
                        ? Color.white : Color(red: 0.8, green: 0.8, blue: 0.8)
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ColorSelectionPopover: View {
    let title: String
    @Binding var selection: Color
    @Binding var opacity: Double
    @State private var model: ColorSelection
    @State private var hexText: String
    @State private var invalidHex = false

    init(title: String, selection: Binding<Color>, opacity: Binding<Double>) {
        self.title = title
        _selection = selection
        _opacity = opacity
        _model = State(initialValue: ColorSelection(color: selection.wrappedValue))
        _hexText = State(initialValue: selection.wrappedValue.toHex())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SaturationBrightnessSurface(
                hue: model.hue,
                saturation: $model.saturation,
                brightness: $model.brightness
            )
            HStack {
                Text("Hue").frame(width: 48, alignment: .leading)
                Slider(value: $model.hue, in: 0...1)
                    .accessibilityLabel("Hue")
            }
            HStack {
                Text("Hex").frame(width: 48, alignment: .leading)
                TextField("#RRGGBB", text: $hexText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Hex color")
                    .onSubmit { commitHex() }
                    .onChange(of: hexText) {
                        invalidHex = false
                        // Partial edits stay local until a complete RGB value exists.
                        if let hex = ColorSelection.normalizedHex(hexText), hex != model.color.toHex() {
                            commitHex()
                        }
                    }
            }
            HStack {
                Text("Opacity").frame(width: 48, alignment: .leading)
                Slider(value: $opacity, in: 0...1, step: 0.05)
                    .accessibilityLabel("\(title) opacity")
                Text("\(Int((opacity * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            if invalidHex {
                Text("Enter six hex digits, for example #355B84.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { AutoHideTrace.record("picker.content.appeared", details: "picker=\(title)", includeWindows: true) }
        .onDisappear { AutoHideTrace.record("picker.content.disappeared", details: "picker=\(title)", includeWindows: true) }
        .onChange(of: opacity) { AutoHideTrace.record("picker.opacity.changed", details: "picker=\(title)") }
        .onChange(of: model.hue) {
            AutoHideTrace.record("picker.hue.changed", details: "picker=\(title)")
            publishColor()
        }
        .onChange(of: model.saturation) {
            AutoHideTrace.record("picker.saturation.changed", details: "picker=\(title)")
            publishColor()
        }
        .onChange(of: model.brightness) {
            AutoHideTrace.record("picker.brightness.changed", details: "picker=\(title)")
            publishColor()
        }
        .onChange(of: selection.toHex()) {
            AutoHideTrace.record("picker.selectionBinding.changed", details: "picker=\(title)")
            // Do not quantize HSV back to RGB after our own updates.
            if selection.toHex() != model.color.toHex() {
                model.update(color: selection)
                hexText = selection.toHex()
                invalidHex = false
            }
        }
    }

    private func publishColor() {
        let color = model.color
        if selection.toHex() != color.toHex() {
            AutoHideTrace.record("picker.publishColor.before", details: "picker=\(title)", includeWindows: true)
            selection = color
            AutoHideTrace.record("picker.publishColor.after", details: "picker=\(title)")
        }
        hexText = color.toHex()
        invalidHex = false
    }

    private func commitHex() {
        guard model.applyHex(hexText) else {
            invalidHex = true
            return
        }
        publishColor()
    }
}

private struct SaturationBrightnessSurface: View {
    let hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                Rectangle().fill(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
                Rectangle().fill(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom))
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().strokeBorder(.black, lineWidth: 4))
                    .frame(width: 12, height: 12)
                    .position(x: saturation * geometry.size.width, y: (1 - brightness) * geometry.size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                AutoHideTrace.record("picker.surface.drag", details: "localX=\(value.location.x) localY=\(value.location.y)")
                saturation = min(max(value.location.x / geometry.size.width, 0), 1)
                brightness = 1 - min(max(value.location.y / geometry.size.height, 0), 1)
            })
        }
        .frame(height: 150)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: saturation = max(0, saturation - 0.01)
            case .right: saturation = min(1, saturation + 0.01)
            case .up: brightness = min(1, brightness + 0.01)
            case .down: brightness = max(0, brightness - 0.01)
            @unknown default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saturation and brightness")
        .accessibilityValue("Saturation \(Int(saturation * 100)) percent, brightness \(Int(brightness * 100)) percent")
        .accessibilityHint("Use left and right arrows for saturation, up and down for brightness.")
    }
}
