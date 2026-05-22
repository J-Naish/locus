import Foundation

enum FuzzyMatching {
    static func isSingleTypoMatch(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        let lengthDifference = lhs.count - rhs.count

        guard abs(lengthDifference) <= 1 else {
            return false
        }

        if lengthDifference == 0 {
            return isSameLengthSingleTypoMatch(lhs, rhs)
        }

        let shorter = lengthDifference < 0 ? lhs : rhs
        let longer = lengthDifference < 0 ? rhs : lhs
        return isSingleInsertionOrDeletionMatch(shorter, longer)
    }

    private static func isSameLengthSingleTypoMatch(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        var mismatchIndices: [Int] = []

        for index in lhs.indices where lhs[index] != rhs[index] {
            mismatchIndices.append(index)
            if mismatchIndices.count > 2 {
                return false
            }
        }

        switch mismatchIndices.count {
        case 0:
            return false
        case 1:
            return true
        case 2:
            let first = mismatchIndices[0]
            let second = mismatchIndices[1]
            return second == first + 1
                && lhs[first] == rhs[second]
                && lhs[second] == rhs[first]
        default:
            return false
        }
    }

    private static func isSingleInsertionOrDeletionMatch(_ shorter: [Character], _ longer: [Character]) -> Bool {
        precondition(longer.count == shorter.count + 1)

        var shorterIndex = 0
        var longerIndex = 0
        var skippedCharacter = false

        while shorterIndex < shorter.count && longerIndex < longer.count {
            if shorter[shorterIndex] == longer[longerIndex] {
                shorterIndex += 1
                longerIndex += 1
                continue
            }

            if skippedCharacter {
                return false
            }

            skippedCharacter = true
            longerIndex += 1
        }

        return true
    }
}
