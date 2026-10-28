import SwiftUI

/// One shared track with two independently adjustable, non-crossing handles.
struct VideoDurationRangeControl: View {
    @Binding var range: VideoDurationRange?
    @State private var activeLower = true
    private var value: VideoDurationRange { range ?? .init() }
    var body: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    endpointMenu(lower: true).fixedSize()
                    Spacer(minLength: 8)
                    endpointMenu(lower: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    endpointMenu(lower: true)
                    endpointMenu(lower: false)
                }
            }
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 44)
                let finiteFraction = Double((width - min(52, width * 0.25)) / width)
                let lower = position(VideoDurationScale.lowerIndex(value), width: width, finiteFraction: finiteFraction)
                let upper = position(VideoDurationScale.upperIndex(value), width: width, finiteFraction: finiteFraction)
                let finiteEnd = position(VideoDurationScale.finiteLastIndex, width: width, finiteFraction: finiteFraction)
                let close = abs(upper - lower) < 44
                ZStack(alignment: .topLeading) {
                    Capsule().fill(.quaternary).frame(height: 4).padding(.horizontal, 22).offset(y: 42)
                    Capsule().fill(Color.accentColor.opacity(range == nil ? 0.35 : 1))
                        .frame(width: max(0, upper - lower), height: 4).offset(x: lower, y: 42)
                    Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: 12).offset(x: finiteEnd, y: 38)
                    ForEach(VideoDurationScale.tickSeconds, id: \.self) { seconds in
                        let x = position(VideoDurationScale.index(for: seconds), width: width, finiteFraction: finiteFraction)
                        Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1, height: 8).offset(x: x, y: 40)
                        Text(VideoDurationScale.title(seconds)).font(.caption2).monospacedDigit()
                            .dynamicTypeSize(...DynamicTypeSize.large).foregroundStyle(.secondary)
                            .fixedSize().position(x: x, y: 104).accessibilityHidden(true)
                    }
                    thumb(lower: true, width: width, finiteFraction: finiteFraction)
                        .position(x: lower, y: close ? 22 : 44).zIndex(activeLower ? 2 : 1)
                    thumb(lower: false, width: width, finiteFraction: finiteFraction)
                        .position(x: upper, y: close ? 66 : 44).zIndex(activeLower ? 1 : 2)
                }.frame(height: 116).coordinateSpace(name: "durationRangeTrack")
            }.frame(height: 116)
        }
    }
    private func position(_ index: Int, width: CGFloat, finiteFraction: Double) -> CGFloat {
        22 + CGFloat(VideoDurationScale.fraction(for: index, finiteFraction: finiteFraction)) * width
    }
    private func moving(to index: Int, lower: Bool) -> VideoDurationRange {
        lower ? VideoDurationScale.movingLower(index, in: value) : VideoDurationScale.movingUpper(index, in: value)
    }
    private func currentIndex(lower: Bool) -> Int {
        lower ? VideoDurationScale.lowerIndex(value) : VideoDurationScale.upperIndex(value)
    }
    private func endpointMenu(lower: Bool) -> some View {
        let index = currentIndex(lower: lower)
        return Menu {
            Button(index == VideoDurationScale.terminalIndex ? "设为02:00" : "减少1秒") { range = moving(to: index - 1, lower: lower) }
                .disabled(moving(to: index - 1, lower: lower) == value)
            if index < VideoDurationScale.terminalIndex {
                Button(index == VideoDurationScale.finiteLastIndex ? (lower ? "超过02:00" : "不限") : "增加1秒") { range = moving(to: index + 1, lower: lower) }
                    .disabled(moving(to: index + 1, lower: lower) == value)
            }
            if index < VideoDurationScale.finiteLastIndex {
                Button(lower ? "超过02:00" : "不限") { range = moving(to: VideoDurationScale.terminalIndex, lower: lower) }
                    .disabled(lower && value.maximumSeconds != nil)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(lower ? "最短" : "最长").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text(lower ? value.minimumTitle : value.maximumTitle).font(.subheadline).monospacedDigit()
                    Image(systemName: "chevron.down").font(.caption2)
                }.foregroundStyle(Color.accentColor)
            }.frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityLabel(lower ? "微调最短视频时长" : "微调最长视频时长")
        .accessibilityValue(lower ? value.minimumTitle : value.maximumTitle)
        .accessibilityIdentifier(lower ? "duration.range.minimum.menu" : "duration.range.maximum.menu")
    }
    private func thumb(lower: Bool, width: CGFloat, finiteFraction: Double) -> some View {
        Capsule().fill(Color(uiColor: .systemBackground)).frame(width: 44, height: 32)
            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2))
            .overlay(Text(lower ? "最短" : "最长").font(.caption2).dynamicTypeSize(...DynamicTypeSize.large).foregroundStyle(Color.accentColor))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("durationRangeTrack"))
                .onChanged { gesture in
                    activeLower = lower
                    let index = VideoDurationScale.index(atFraction: Double((gesture.location.x - 22) / width), finiteFraction: finiteFraction)
                    range = moving(to: index, lower: lower)
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lower ? "最短视频时长" : "最长视频时长")
            .accessibilityIdentifier(lower ? "duration.range.minimum" : "duration.range.maximum")
            .accessibilityValue(lower ? value.minimumTitle : value.maximumTitle)
            .accessibilityAdjustableAction { direction in
                activeLower = lower
                let delta = direction == .increment ? 1 : -1
                range = moving(to: currentIndex(lower: lower) + delta, lower: lower)
            }
    }
}
