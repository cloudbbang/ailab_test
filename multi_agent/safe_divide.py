import logging
import math

logger = logging.getLogger(__name__)


def safe_divide(a: float, b: float) -> float | None:
    """Safely divide two numbers, returning None if division is not possible.

    Args:
        a: The numerator. Must be int or float (bool is rejected).
        b: The denominator. Must be int or float (bool is rejected).

    Returns:
        The result of a / b as a float, or None if:
            - Either argument is a bool.
            - Either argument is not a numeric type (int or float).
            - b is zero.
            - The result is non-finite (inf or nan).
    """
    if isinstance(a, bool) or isinstance(b, bool):
        logger.error("Invalid input: bool types are not accepted (a=%r, b=%r).", a, b)
        return None

    try:
        result = a / b
    except ZeroDivisionError:
        logger.error("Cannot divide %s by zero.", a)
        return None
    except TypeError:
        logger.error(
            "Invalid types for division: %s, %s.",
            type(a).__name__,
            type(b).__name__,
        )
        return None

    if not math.isfinite(result):
        logger.error("Non-finite result: %s / %s = %s.", a, b, result)
        return None

    return result


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)
    print(safe_divide(10, 2))
    print(safe_divide(10, 0))
    print(safe_divide(10, "a"))
    print(safe_divide(-7, 2))
    print(safe_divide(0, 5))
    print(safe_divide(True, 2))
    print(safe_divide(1e308, 1e-308))
    print(safe_divide(float("inf"), 1))

