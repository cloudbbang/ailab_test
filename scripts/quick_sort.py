def quick_sort(arr):
    if len(arr) <= 1:
        return arr
    pivot = arr[len(arr) // 2]
    left = [x for x in arr if x < pivot]
    middle = [x for x in arr if x == pivot]
    right = [x for x in arr if x > pivot]
    return quick_sort(left) + middle + quick_sort(right)


def main():
    data = [38, 27, 43, 3, 9, 82, 10]
    print("정렬 전:", data)

    sorted_data = quick_sort(data)
    print("정렬 후:", sorted_data)

    # 결과 검증
    expected = sorted(data)
    if sorted_data == expected:
        print("검증 성공: 정렬 결과가 올바릅니다.")
    else:
        print("검증 실패: 예상", expected, "/ 실제", sorted_data)


if __name__ == "__main__":
    main()
