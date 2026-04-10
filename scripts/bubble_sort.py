def bubble_sort(arr):
    arr = arr[:]
    n = len(arr)
    for i in range(n - 1):
        for j in range(n - 1 - i):
            if arr[j] > arr[j + 1]:
                arr[j], arr[j + 1] = arr[j + 1], arr[j]
    return arr


def main():
    data = [38, 27, 43, 3, 9, 82, 10]
    print("정렬 전:", data)

    sorted_data = bubble_sort(data)
    print("정렬 후:", sorted_data)

    # 결과 검증
    expected = sorted(data)
    if sorted_data == expected:
        print("검증 성공: 정렬 결과가 올바릅니다.")
    else:
        print("검증 실패: 예상", expected, "/ 실제", sorted_data)


if __name__ == "__main__":
    main()
