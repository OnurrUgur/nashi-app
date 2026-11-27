import XCTest
import PDFKit
@testable import NashiCore

final class PDFSignatureDetectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try OutputFiles.temporaryDirectory() }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testMetadataCleanupRefusesCertifiedAndReachableSignedPDFs() throws {
        let certified = try pdf(
            name: "Certified.pdf",
            catalogExtra: "/Perms << /DocMDP 5 0 R >>",
            extraObjects: ["<< /Type /Sig /ByteRange [0 10 20 30] >>"]
        )
        let directUntyped = try pdf(
            name: "DirectCertified.pdf",
            catalogExtra: "/Perms << /DocMDP << /ByteRange [0 10 20 30] >> >>"
        )
        let inlineFormSig = try pdf(
            name: "InlineSignedForm.pdf",
            catalogExtra: "/AcroForm << /Fields [5 0 R] >>",
            pageAnnots: "5 0 R",
            extraObjects: [
                "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /P 3 0 R /Rect [10 10 100 40] /V << /ByteRange [0 10 20 30] >> >>"
            ]
        )

        for input in [certified, directUntyped, inlineFormSig] {
            let before = try Data(contentsOf: input)
            let folder = root.appendingPathComponent(input.deletingPathExtension().lastPathComponent, isDirectory: true)
            var options = OperationOptions()
            options.metadataRemoveAll = true
            options.outputDirectory = folder
            XCTAssertThrowsError(try ConversionEngine.run(.init(inputs: [input], operation: .tool(.removeMetadata), options: options)), input.lastPathComponent) { error in
                XCTAssertTrue(error.localizedDescription.contains("digital signatures"), "\(input.lastPathComponent): \(error.localizedDescription)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertEqual(try Data(contentsOf: input), before)
        }
    }

    func testPageOperationsDetectInlineReachableSignaturesWithoutPerms() throws {
        let inlineSigned = try pdf(
            name: "InlineSignedWithoutPerms.pdf",
            catalogExtra: "/CustomStamp << /ByteRange [0 10 20 30] >>"
        )
        let plain = try pdf(name: "Plain.pdf")
        var options = OperationOptions()
        options.outputDirectory = root.appendingPathComponent("inline-merge", isDirectory: true)
        XCTAssertThrowsError(try ConversionEngine.run(.init(inputs: [plain, inlineSigned], operation: .tool(.mergePDF), options: options))) { error in
            XCTAssertTrue(error.localizedDescription.contains("digital signatures"), error.localizedDescription)
        }
        var splitOptions = OperationOptions()
        splitOptions.pageRanges = "1"
        splitOptions.outputDirectory = root.appendingPathComponent("inline-split", isDirectory: true)
        XCTAssertThrowsError(try ConversionEngine.run(.init(inputs: [inlineSigned], operation: .tool(.splitPDF), options: splitOptions))) { error in
            XCTAssertTrue(error.localizedDescription.contains("digital signatures"), error.localizedDescription)
        }
    }

    func testUnreachableIncrementalSignatureDoesNotRefusePageOperationsOrCleanup() throws {
        let plain = try pdf(name: "PlainBase.pdf")
        let incremental = try appendUnreachableSignature(to: plain, name: "RemovedSigLater.pdf")

        var mergeOptions = OperationOptions()
        mergeOptions.outputDirectory = root.appendingPathComponent("merge-unreachable", isDirectory: true)
        let merged = try ConversionEngine.run(.init(inputs: [plain, incremental], operation: .tool(.mergePDF), options: mergeOptions))
        XCTAssertEqual(try PDFEngine.open(XCTUnwrap(merged.first)).pageCount, 2)

        var splitOptions = OperationOptions()
        splitOptions.pageRanges = "1"
        splitOptions.outputDirectory = root.appendingPathComponent("split-unreachable", isDirectory: true)
        let split = try ConversionEngine.run(.init(inputs: [incremental], operation: .tool(.splitPDF), options: splitOptions))
        XCTAssertEqual(try PDFEngine.open(XCTUnwrap(split.first)).pageCount, 1)

        var cleanOptions = OperationOptions()
        cleanOptions.metadataRemoveAll = true
        cleanOptions.outputDirectory = root.appendingPathComponent("clean-unreachable", isDirectory: true)
        let cleaned = try ConversionEngine.run(.init(inputs: [incremental], operation: .tool(.removeMetadata), options: cleanOptions))
        XCTAssertEqual(try PDFEngine.open(XCTUnwrap(cleaned.first)).pageCount, 1)
    }

    func testUnsignedSignatureFieldIsNotReportedAsDigitalSignature() throws {
        let unsignedField = try pdf(
            name: "UnsignedField.pdf",
            catalogExtra: "/AcroForm 6 0 R",
            pageAnnots: "5 0 R",
            extraObjects: [
                "<< /Type /Annot /Subtype /Widget /FT /Sig /T (SignHere) /P 3 0 R /Rect [10 10 100 40] >>",
                "<< /Fields [5 0 R] >>"
            ]
        )
        let plain = try pdf(name: "PlainForUnsigned.pdf")
        var mergeOptions = OperationOptions()
        mergeOptions.outputDirectory = root.appendingPathComponent("merge-unsigned", isDirectory: true)
        let merged = try ConversionEngine.run(.init(inputs: [plain, unsignedField], operation: .tool(.mergePDF), options: mergeOptions))
        XCTAssertEqual(try PDFEngine.open(XCTUnwrap(merged.first)).pageCount, 2)

        var cleanOptions = OperationOptions()
        cleanOptions.metadataRemoveAll = true
        cleanOptions.outputDirectory = root.appendingPathComponent("clean-unsigned", isDirectory: true)
        XCTAssertThrowsError(try ConversionEngine.run(.init(inputs: [unsignedField], operation: .tool(.removeMetadata), options: cleanOptions))) { error in
            XCTAssertTrue(error.localizedDescription.contains("form fields"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("digital signatures"), error.localizedDescription)
        }
    }

    private func pdf(name: String, catalogExtra: String = "", pageAnnots: String = "", extraObjects: [String] = []) throws -> URL {
        let stream = "BT /F1 12 Tf 20 100 Td (Public) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R \(catalogExtra) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 120] /Contents 4 0 R \(pageAnnots.isEmpty ? "" : "/Annots [\(pageAnnots)]") >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        ] + extraObjects
        var data = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func appendUnreachableSignature(to source: URL, name: String) throws -> URL {
        var bytes = try Data(contentsOf: source)
        let text = String(decoding: bytes, as: UTF8.self)
        let sizeRange = try XCTUnwrap(text.range(of: #"/Size (\d+)"#, options: .regularExpression))
        let size = try XCTUnwrap(Int(text[sizeRange].split(separator: " ").last ?? ""))
        let startXrefRange = try XCTUnwrap(text.range(of: #"startxref\n(\d+)"#, options: .regularExpression))
        let prev = try XCTUnwrap(Int(text[startXrefRange].split(separator: "\n").last ?? ""))
        let objectOffset = bytes.count
        var update = "\n\(size) 0 obj\n<< /Type /Sig /ByteRange [0 10 20 30] >>\nendobj\n"
        let xrefOffset = objectOffset + update.utf8.count
        update += "xref\n\(size) 1\n\(String(format: "%010d", objectOffset + 1)) 00000 n \n"
        update += "trailer\n<< /Size \(size + 1) /Root 1 0 R /Prev \(prev) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        bytes.append(Data(update.utf8))
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}
