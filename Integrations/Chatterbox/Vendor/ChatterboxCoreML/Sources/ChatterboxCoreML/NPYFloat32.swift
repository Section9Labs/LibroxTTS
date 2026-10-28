import Foundation

/// Minimal `.npy` (v1.0/v2.0) reader for little-endian Float32, C-order arrays.
/// Shared by the host-side embedding / projection tables the padded T3 prefill
/// contract requires (`speech_emb.npy`, `text_emb.npy`, `spkr_enc_weight.npy`,
/// `spkr_enc_bias.npy`).
enum NPYFloat32 {
    /// Validates the Float32 C-order header at the start of `raw` — which need only
    /// contain the header block, not the payload (see ``shape(url:)``) — and returns
    /// the array's shape plus the payload's byte offset.
    private static func parseHeader(_ raw: Data) throws -> (shape: [Int], payloadStart: Int) {
        guard raw.count > 10 else { throw ChatterboxError.npy("file too small") }
        // Magic string: \x93NUMPY
        let magic: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]
        guard Array(raw[0..<6]) == magic else { throw ChatterboxError.npy("bad magic") }
        let major = raw[6]
        // Header length field: 2 bytes (v1) or 4 bytes (v2+), little-endian.
        let headerLenSize = major >= 2 ? 4 : 2
        let headerLenOffset = 8
        var headerLen = 0
        for i in 0..<headerLenSize {
            headerLen |= Int(raw[headerLenOffset + i]) << (8 * i)
        }
        let headerStart = headerLenOffset + headerLenSize
        let headerEnd = headerStart + headerLen
        guard headerEnd <= raw.count,
              let header = String(data: raw[headerStart..<headerEnd], encoding: .ascii) else {
            throw ChatterboxError.npy("unreadable header")
        }

        guard header.contains("'<f4'") || header.contains("\"<f4\"") else {
            throw ChatterboxError.npy("unsupported dtype (expected <f4); header: \(header)")
        }
        guard !header.contains("'fortran_order': True") else {
            throw ChatterboxError.npy("fortran-order arrays are not supported")
        }

        // Parse shape tuple, e.g. "'shape': (6563, 1024)"
        guard let shapeRange = header.range(of: "'shape':") else {
            throw ChatterboxError.npy("no shape in header")
        }
        let afterShape = header[shapeRange.upperBound...]
        guard let open = afterShape.firstIndex(of: "("),
              let close = afterShape.firstIndex(of: ")") else {
            throw ChatterboxError.npy("malformed shape tuple")
        }
        let inner = afterShape[afterShape.index(after: open)..<close]
        let shape = inner.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
        return (shape, headerEnd)
    }

    /// Parses a Float32 `.npy` file, returning its flat C-order data and shape.
    static func read(url: URL) throws -> (data: [Float], shape: [Int]) {
        let raw = try Data(contentsOf: url)
        let (shape, payloadStart) = try parseHeader(raw)
        let payload = raw[payloadStart...]
        let count = payload.count / MemoryLayout<Float>.size
        let floats = payload.withUnsafeBytes { buf -> [Float] in
            let ptr = buf.bindMemory(to: Float.self)
            return Array(ptr.prefix(count))
        }
        return (floats, shape)
    }

    /// The shape from the **header alone** — the payload is never read, so probing a
    /// 27 MB table costs one 4 KB read (npy headers are ≤ a few hundred bytes). `nil`
    /// if the file is missing or unparseable. Lets a model directory's T3 width be
    /// checked *before* its tables load; see ``ModelRepository/detectVariant(in:)``.
    static func shape(url: URL) -> [Int]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let raw = try? h.read(upToCount: 4096) else { return nil }
        return (try? parseHeader(raw))?.shape
    }
}

/// A 2-D `(rows, cols)` Float32 embedding table loaded from `.npy`, with
/// per-row lookups used to assemble `inputs_embeds` host-side.
struct EmbeddingTable: Sendable {
    let rows: Int
    let cols: Int
    private let table: [Float] // row-major: rows * cols

    init(contentsOf url: URL, name: String) throws {
        let (data, shape) = try NPYFloat32.read(url: url)
        guard shape.count == 2 else {
            throw ChatterboxError.npy("\(name) expected 2-D, got shape \(shape)")
        }
        self.rows = shape[0]
        self.cols = shape[1]
        self.table = data
        guard table.count == rows * cols else {
            throw ChatterboxError.npy("\(name) element count \(table.count) != \(rows)*\(cols)")
        }
    }

    /// Appends the `cols`-length embedding row for `token` to `out`.
    func appendRow(_ token: Int, to out: inout [Float]) {
        let start = token * cols
        out.append(contentsOf: table[start..<start + cols])
    }

    /// Returns the `cols`-length embedding row for `token`.
    func row(_ token: Int) -> [Float] {
        let start = token * cols
        return Array(table[start..<start + cols])
    }
}

/// The `spkr_enc` linear layer (`256 → 1024`): `y = W·x + b`. `W` is row-major
/// `(out, in)` as exported by NumPy from the PyTorch `nn.Linear` weight.
struct SpeakerProjection: Sendable {
    let outDim: Int
    let inDim: Int
    private let weight: [Float] // (out, in) row-major
    private let bias: [Float]   // (out)

    init(weightURL: URL, biasURL: URL) throws {
        let (w, wShape) = try NPYFloat32.read(url: weightURL)
        let (b, bShape) = try NPYFloat32.read(url: biasURL)
        guard wShape.count == 2 else {
            throw ChatterboxError.npy("spkr_enc_weight expected 2-D, got \(wShape)")
        }
        guard bShape.count == 1, bShape[0] == wShape[0] else {
            throw ChatterboxError.npy("spkr_enc_bias shape \(bShape) incompatible with weight \(wShape)")
        }
        self.outDim = wShape[0]
        self.inDim = wShape[1]
        self.weight = w
        self.bias = b
        guard weight.count == outDim * inDim else {
            throw ChatterboxError.npy("spkr_enc_weight element count \(weight.count) != \(outDim)*\(inDim)")
        }
    }

    /// Projects a `inDim` speaker embedding to an `outDim` row.
    func project(_ x: [Float]) -> [Float] {
        precondition(x.count == inDim, "speaker embedding dim \(x.count) != \(inDim)")
        var out = bias // copy; accumulate W·x on top
        weight.withUnsafeBufferPointer { w in
            x.withUnsafeBufferPointer { xp in
                for o in 0..<outDim {
                    var acc = out[o]
                    let base = o * inDim
                    for i in 0..<inDim { acc += w[base + i] * xp[i] }
                    out[o] = acc
                }
            }
        }
        return out
    }
}
