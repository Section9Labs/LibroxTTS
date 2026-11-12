import Foundation
import MLX
import XCTest
@testable import PocketTTSMLX

/// Frozen concatenation semantics, including externally writable offset.
private final class ReferenceCache09 {
    var offset = 0
    var keys: MLXArray?, values: MLXArray?
    var state: [MLXArray] {
        get { guard let keys, let values else { return [] }; return [keys, values] }
        set { keys = newValue[0]; values = newValue[1]; offset = newValue[0].shape[2] }
    }
    func update(_ key: MLXArray, _ value: MLXArray) -> [MLXArray] {
        keys = keys.map { concatenated([$0, key], axis: 2) } ?? key
        values = values.map { concatenated([$0, value], axis: 2) } ?? value
        offset += key.shape[2]
        return state
    }
    func trim(_ count: Int) -> Int {
        let n = min(offset, max(0, count)); offset -= n
        if offset == 0 { keys = nil; values = nil }
        else { keys = keys?[.ellipsis, ..<offset, 0...]; values = values?[.ellipsis, ..<offset, 0...] }
        return n
    }
}

final class CacheContract09Tests: XCTestCase {
    func testPublishedStateRetainsExistingReferenceSemantics() {
        PocketTestMetal.configure()
        Device.withDefaultDevice(.cpu) {
            let old = ReferenceCache09(), new = KVCacheSimple()
            let frame = MLXArray.ones([1, 2, 3, 4])
            _ = old.update(frame, frame); _ = new.update(keys: frame, values: frame)
            let oldState = old.state, newState = new.state
            // MLXArray is a reference type. Clients can mutate a returned array;
            // the existing public cache observes that mutation on its next append.
            oldState[0][.ellipsis, 0..<1, 0...] = MLXArray.zeros([1, 2, 1, 4])
            newState[0][.ellipsis, 0..<1, 0...] = MLXArray.zeros([1, 2, 1, 4])
            let expected = old.update(frame, frame), actual = new.update(keys: frame, values: frame)
            XCTAssertEqual(expected[0].asArray(Float.self), actual.0.asArray(Float.self))
        }
    }

    func testAppendSnapshotsTrimAndRestorationOnBothDevices() {
        PocketTestMetal.configure()
        for device in [Device.cpu, .gpu] {
            Device.withDefaultDevice(device) {
                let old = ReferenceCache09(), new = KVCacheSimple()
                func equal(_ a: [MLXArray], _ b: [MLXArray]) {
                    XCTAssertEqual(a.count, b.count)
                    for (x,y) in zip(a,b) {
                        XCTAssertEqual(x.shape,y.shape)
                        XCTAssertEqual(x.asArray(Float.self),y.asArray(Float.self))
                    }
                    XCTAssertEqual(old.offset,new.offset)
                }
                var frozen: [[MLXArray]] = [], frozenValues: [[[Float]]] = []
                for (i,n) in [127,1,128,3,257,1].enumerated() {
                    let k = MLXArray(Array(0..<(2*n*4)).map { Float($0+i*100) },[1,2,n,4])
                    let v = k * 0.25
                    let expected = old.update(k,v), pair = new.update(keys:k,values:v)
                    equal(expected,[pair.0,pair.1])
                    frozen.append(new.state); frozenValues.append(expected.map { $0.asArray(Float.self) })
                }
                for count in [-1,0,2,255,50] {
                    XCTAssertEqual(old.trim(count),new.trim(count)); equal(old.state,new.state)
                }
                // Restoring snapshots, then appending, must not mutate published tensors.
                old.state = frozen[1]; new.state = frozen[1]
                let frame = MLXArray.ones([1,2,3,4])
                equal(old.update(frame,frame), { let p = new.update(keys:frame,values:frame); return [p.0,p.1] }())
                old.offset = 2; new.offset = 2
                equal(old.update(frame,frame), { let p = new.update(keys:frame,values:frame); return [p.0,p.1] }())
                XCTAssertEqual(old.trim(1),new.trim(1)); equal(old.state,new.state)
                XCTAssertEqual(old.trim(10000),new.trim(10000)); equal(old.state,new.state)
                equal(old.update(frame,frame), { let p = new.update(keys:frame,values:frame); return [p.0,p.1] }())
                for (snap,values) in zip(frozen,frozenValues) {
                    XCTAssertEqual(snap.map { $0.asArray(Float.self) },values)
                }
            }
        }
    }
}
