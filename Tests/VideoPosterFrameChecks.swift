import Foundation
import CoreVideo
import CoreGraphics
import ImageIO

@main struct VideoPosterFrameChecks {
    static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        let palette: [[UInt8]] = [[235,30,30],[30,220,40],[30,45,230],[230,220,25]]
        func buffer(_ width: Int, _ height: Int) -> VideoPosterPixelBuffer {
            var value: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &value) == kCVReturnSuccess)
            let output = value!
            CVPixelBufferLockBaseAddress(output, []); defer { CVPixelBufferUnlockBaseAddress(output, []) }
            let base = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(output)
            for y in 0..<height { for x in 0..<width {
                let color = palette[(y < height/2 ? 0 : 2) + (x < width/2 ? 0 : 1)], at = y*stride+x*4
                base[at] = color[2]; base[at+1] = color[1]; base[at+2] = color[0]; base[at+3] = 255
            } }
            return VideoPosterPixelBuffer(output)
        }
        func corners(_ data: Data) -> [Int] {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let width = image.width, height = image.height
            let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width*height*4); defer { data.deallocate() }
            let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return [(width/8,height/8),(width*7/8,height/8),(width/8,height*7/8),(width*7/8,height*7/8)].map { x,y in
                let at = y*width*4+x*4
                return palette.indices.min { left,right in
                    func distance(_ index: Int) -> Int { (0..<3).reduce(0) { total,c in total + abs(Int(data[at+c])-Int(palette[index][c])) } }
                    return distance(left)<distance(right)
                }!
            }
        }
        let frame = buffer(800,600)
        let cases: [(String,CGAffineTransform,[Int],Int,Int)] = [
            ("identity",.identity,[0,1,2,3],512,384),
            ("90 clockwise",CGAffineTransform(a:0,b:1,c:-1,d:0,tx:600,ty:0),[2,0,3,1],384,512),
            ("180",CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:800,ty:600),[3,2,1,0],512,384),
            ("270 clockwise",CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:800),[1,3,0,2],384,512),
            ("horizontal mirror",CGAffineTransform(a:-1,b:0,c:0,d:1,tx:800,ty:0),[1,0,3,2],512,384)
        ]
        for (name,transform,expected,width,height) in cases {
            let jpeg = try VideoPosterFrame.render(frame, preferredTransform: transform)
            let actual = corners(jpeg.data)
            print("POSTER_FRAME \(name) corners=\(actual) expected=\(expected)")
            check(jpeg.width==width && jpeg.height==height, "Display transform must produce the expected bounded dimensions")
            check(actual==expected, "Independent four-corner pattern must preserve orientation: " + name)
            check(jpeg.data.count>0 && jpeg.data.count<=1_048_576, "Encoded preview stays within1MiB")
        }
        for transform in [CGAffineTransform(a:0,b:0,c:0,d:0,tx:0,ty:0),CGAffineTransform(a:.nan,b:0,c:0,d:1,tx:0,ty:0)] {
            do { _ = try VideoPosterFrame.render(frame, preferredTransform: transform); preconditionFailure("Invalid transform accepted") }
            catch VideoPosterFrameError.unsupported { checks += 1 }
        }
        do { _ = try VideoPosterFrame.render(buffer(5000,2), preferredTransform:.identity); preconditionFailure("Oversized decoded frame accepted") }
        catch VideoPosterFrameError.unsupported { checks += 1 }
        let hdr = buffer(32,24)
        CVBufferSetAttachment(hdr.value, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        do { _ = try VideoPosterFrame.render(hdr, preferredTransform:.identity); preconditionFailure("Unvalidated HDR conversion accepted") }
        catch VideoPosterFrameError.unsupported { checks += 1 }
        let cancelled = Task { () throws -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try VideoPosterFrame.render(frame, preferredTransform:.identity)
            return true
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancelled frame render succeeded") }
        catch is CancellationError { checks += 1 }
        print("VideoPosterFrameChecks: \(checks) local assertions passed")
    }
}
