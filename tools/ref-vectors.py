#!/usr/bin/env python3
import hashlib, hmac
print("pbkdf2:", hashlib.pbkdf2_hmac('sha256', b'password', b'salt', 4096, 32).hex())
print("hmac:  ", hmac.new(b'key', b'The quick brown fox jumps over the lazy dog',
                         hashlib.sha256).hexdigest())
