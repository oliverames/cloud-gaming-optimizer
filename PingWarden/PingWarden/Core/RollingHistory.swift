//
//  RollingHistory.swift
//  PingWarden
//
//  An append-optimized history buffer that advances a logical head instead
//  of shifting the entire array for every expired telemetry sample.
//

import Foundation

struct RollingHistory<Element> {
    private var storage: [Element] = []
    private var firstValidIndex = 0

    var count: Int {
        storage.count - firstValidIndex
    }

    var isEmpty: Bool {
        count == 0
    }

    var elements: [Element] {
        guard firstValidIndex < storage.count else { return [] }
        return Array(storage[firstValidIndex...])
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func removePrefix(while shouldRemove: (Element) -> Bool) {
        while firstValidIndex < storage.count, shouldRemove(storage[firstValidIndex]) {
            firstValidIndex += 1
        }
        compactIfNeeded()
    }

    mutating func trimToLast(_ maximumCount: Int) {
        let sanitizedMaximum = max(0, maximumCount)
        if count > sanitizedMaximum {
            firstValidIndex += count - sanitizedMaximum
        }
        compactIfNeeded()
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        firstValidIndex = 0
    }

    func last(where predicate: (Element) -> Bool) -> Element? {
        guard firstValidIndex < storage.count else { return nil }
        for index in stride(from: storage.count - 1, through: firstValidIndex, by: -1) {
            let element = storage[index]
            if predicate(element) {
                return element
            }
        }
        return nil
    }

    private mutating func compactIfNeeded() {
        guard firstValidIndex > 0 else { return }

        if firstValidIndex == storage.count {
            storage.removeAll(keepingCapacity: true)
            firstValidIndex = 0
        } else if firstValidIndex >= 1_024 && firstValidIndex * 2 >= storage.count {
            storage.removeFirst(firstValidIndex)
            firstValidIndex = 0
        }
    }
}
