import sys


def safe(value):
    return int(value)


def unsafe(value):
    return eval(value)


print(safe(sys.argv[1]), unsafe(sys.argv[2]))
