import Foundation
import Testing
@testable import AgentHUDSupport

@Test func preservesLargeIntegerCounters() throws {
    let counter: Int64 = 9_007_199_254_740_993
    let value = try JSONDecoder().decode(JSONValue.self, from: Data("{\"tokens\":9007199254740993}".utf8))
    #expect(value == .object(["tokens": .integer(counter)]))
    #expect(String(decoding: try RecordCoding.encoder().encode(value), as: UTF8.self) == "{\"tokens\":9007199254740993}")
}

@Test func parsingReadsWhatTheDecoderReads() throws {
    let numbers = ["0", "-0", "1.0", "1.5", "1e3", "-2.5E-3", "9223372036854775807", "9223372036854775808", "-9223372036854775809",
                   "9007199254740993.0", "18446744073709551616", "1e400", "01", "1."]
    let texts = numbers.flatMap { [$0, "[\($0)]", "{\"n\":\($0)}"] } + [
        #""\u00e9\ud83d\ude00 \" \\ \/ \b\f\n\r\t""#, #""\ud83d""#, "\"é中😀\"", #"{"a":{"b":[true,false,null]}}"#,
        #"{"a":1,"a":2}"#, "[1,]", "\u{FEFF}{\"a\":1}", " [ 1 , 2 ] ", "[1 2]", "", "nul",
    ]
    for data in texts.map({ Data($0.utf8) }) + [Data([0x22, 0xFF, 0x22]), Data([0x7B, 0x22, 0xC3, 0x22, 0x3A, 0x31, 0x7D])] {
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        #expect((try? JSONValue.parse(data)) == decoded, "\(String(decoding: data, as: UTF8.self))")
    }
    #expect(try JSONValue.parse(Data("9007199254740993.0".utf8)) == .integer(9_007_199_254_740_993), "whole numbers keep every digit")
}

@Test func recordIdentitiesHaveUnambiguousComponents() {
    #expect(RecordCoding.hash(["ab", "c"]) != RecordCoding.hash(["a", "bc"]))
    #expect(RecordCoding.hash(["", "a"]) != RecordCoding.hash(["a", ""]))
    #expect(RecordCoding.hash([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test func datesRoundTripAtMillisecondPrecision() throws {
    struct Sample: Codable, Equatable { var at: Date; var count: Int64 }
    let sample = Sample(at: RecordCoding.date(1_700_000_000_123), count: 9_007_199_254_740_993)
    let value = try JSONValue.from(sample)
    #expect(try value.decode(Sample.self) == sample)
    #expect(RecordCoding.milliseconds(sample.at) == 1_700_000_000_123)
}
