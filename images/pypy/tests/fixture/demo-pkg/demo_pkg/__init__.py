import sys


def greet(name):
    return "hello %s from %s" % (name, sys.implementation.name)
