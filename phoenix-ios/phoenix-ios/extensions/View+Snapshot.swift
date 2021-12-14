import SwiftUI

extension View {
	func snapshot(size: CGSize? = nil, crop: CGRect? = nil) -> Image {
		let controller = UIHostingController(rootView: self)
		let view = controller.view

		let targetSize = size ?? controller.view.intrinsicContentSize
		view?.bounds = CGRect(origin: .zero, size: targetSize)
		view?.backgroundColor = .clear

		let renderer = UIGraphicsImageRenderer(size: targetSize)
		
		let sourceImage = renderer.image { _ in
			view?.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
		}
		
		return Image(uiImage: sourceImage)
	}
}
