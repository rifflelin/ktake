import SwiftUI

struct VocalTuningControls: View {
    @Binding var tuning: VocalTuning
    @State private var expanded = false
    @State private var section: Section = .tone

    private enum Section: String, CaseIterable {
        case tone = "均衡"
        case dynamics = "动态"
        case space = "空间"
    }

    var body: some View {
        DisclosureGroup("进阶调音", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("调音分类", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch section {
                case .tone:
                    slider("低切", $tuning.lowCut, VocalTuning.lowCutRange, step: 5,
                           display: "\(Int(tuning.lowCut)) Hz")
                        .help("削弱低频震动和喷麦声。")
                    slider("厚度", $tuning.warmth, VocalTuning.toneRange, step: 0.5,
                           display: String(format: "%+.1f dB", tuning.warmth))
                        .help("调整 260 Hz 附近的低中频。")
                    slider("空气感", $tuning.air, VocalTuning.toneRange, step: 0.5,
                           display: String(format: "%+.1f dB", tuning.air))
                        .help("调整 8 kHz 以上的高频。")
                case .dynamics:
                    slider("噪声门", $tuning.gateThreshold, VocalTuning.gateRange, step: 1,
                           display: tuning.gateEnabled ? "\(Int(tuning.gateThreshold)) dB" : "关闭")
                        .help("降低停唱间隙的底噪。滑到最左关闭。")
                    slider("起音", $tuning.attackMS, VocalTuning.attackRange, step: 1,
                           display: "\(Int(tuning.attackMS)) ms")
                        .help("压缩对大声信号开始起作用的速度。")
                    slider("释放", $tuning.releaseMS, VocalTuning.releaseRange, step: 5,
                           display: "\(Int(tuning.releaseMS)) ms")
                        .help("声音变小后，压缩恢复的速度。")
                case .space:
                    Picker("混响类型", selection: $tuning.room) {
                        ForEach(VocalRoom.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    slider("回声", $tuning.echo, VocalTuning.echoRange, step: 1,
                           display: "\(Int(tuning.echo))%")
                    slider("回声间隔", $tuning.echoTimeMS, VocalTuning.echoTimeRange, step: 5,
                           display: "\(Int(tuning.echoTimeMS)) ms")
                        .disabled(tuning.echo == 0)
                    slider("回声反馈", $tuning.echoFeedback, VocalTuning.echoFeedbackRange, step: 1,
                           display: "\(Int(tuning.echoFeedback))%")
                        .disabled(tuning.echo == 0)
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 11))
        .controlSize(.small)
    }

    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>,
                        step: Float, display: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 55, alignment: .leading)
            Slider(value: value, in: range, step: step).accessibilityLabel(title).accessibilityValue(display)
            Text(display).monospacedDigit().foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
        }
    }
}
