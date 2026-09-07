"""ho16 共享层：两个 Lambda 函数共同依赖的工具库（演示 Layer 复用）。"""
VERSION = "layer-v1"

def greet(name):
    return f"hello {name} from {VERSION}"
