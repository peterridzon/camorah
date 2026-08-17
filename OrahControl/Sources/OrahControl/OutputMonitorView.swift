import SwiftUI
import OrahKit

/// The four lanes leaving for the stitcher, at the size they leave at.
///
/// The desk shows one lens because the operator is judging framing. This answers
/// a different question — what the output actually looks like — and that cannot
/// be judged on a thumbnail. Compression artefacts, a lane that froze, a lens
/// that never started: all of it is invisible until the four are side by side.
///
/// It costs nothing to run. These frames are already composited for the encoder;
/// the window is looking at the same buffers, not making new ones.
@MainActor
struct OutputMonitorView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { geometry in
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(Switcher.lenses.enumerated()), id: \.offset) { index, lens in
                        OutputLane(lens: lens,
                                   lensIndex: index,
                                   sink: model.outputSinks[index],
                                   hasPicture: model.programHasPicture)
                            .frame(height: (geometry.size.height - 2) / 2)
                    }
                }
            }
            .background(.black)

            footer
        }
        .background(Theme.bg)
        .frame(minWidth: 720, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("OUTPUT MONITOR")
                .font(Theme.label(10)).tracking(2.4)
                .foregroundStyle(Theme.dim)

            Text(destination)
                .font(Theme.value(11))
                .foregroundStyle(Theme.faint)

            Spacer()

            Text(model.programHasPicture ? "● ON AIR" : "NO OUTPUT")
                .font(Theme.label(9.5)).tracking(1.6)
                .foregroundStyle(model.programHasPicture ? .white : Theme.faint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background { if model.programHasPicture { Theme.program } }
                .overlay {
                    if !model.programHasPicture {
                        RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panel)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("These are the four streams Vahana pulls — full size, after the dissolve and the encoder.")
                .font(Theme.value(10.5))
                .foregroundStyle(Theme.faint)
            Spacer()
            Text("1920×1440 · 29.97p · CFR")
                .font(Theme.value(10.5))
                .foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var destination: String {
        "rtmp://127.0.0.1:\(model.configuration.rtmpPort)/program/"
    }
}

/// One lane, filling its quarter.
@MainActor
private struct OutputLane: View {
    let lens: String
    let lensIndex: Int
    let sink: VideoSink
    let hasPicture: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.black)
            VideoView(sink: sink, lens: lensIndex)

            if !hasPicture {
                Text("NO OUTPUT")
                    .font(Theme.label(9.5)).tracking(1.8)
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(lens)
                .font(Theme.value(10.5))
                .foregroundStyle(Theme.yellow)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.black.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(7)
        }
    }
}
