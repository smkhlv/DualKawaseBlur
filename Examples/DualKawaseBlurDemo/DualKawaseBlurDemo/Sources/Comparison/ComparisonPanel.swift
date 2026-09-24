import SwiftUI

struct ComparisonPanel: View {
    let title: String
    let detail: String
    let image: UIImage?
    let material: ComparisonMaterial?
    let size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                Rectangle().fill(.background)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                    if let material {
                        // Keep the actual photo in the backdrop. Do not rasterize this subtree.
                        Rectangle()
                            .fill(.clear)
                            .background(material.value, ignoresSafeAreaEdges: [])
                    }
                } else {
                    ProgressView().accessibilityLabel("Preparing comparison")
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(detail)")
        }
    }
}
