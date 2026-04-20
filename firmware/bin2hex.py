import sys

def bin_to_hex(bin_file, hex_file):
    with open(bin_file, 'rb') as f:
        data = f.read()
    with open(hex_file, 'w') as f:
        for byte in data:
            f.write(f"{byte:02x}\n")

if __name__ == "__main__":
    bin_to_hex(sys.argv[1], sys.argv[2])