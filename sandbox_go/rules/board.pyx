# Copyright (c) 2018 Karl Sundequist Blomdahl <karl.sundequist.blomdahl@gmail.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

from .color cimport opposite

cdef void neighbours(int index, int *out) nogil:
    """ Returns an array containing the index of all neighbours to the given
    index. """

    out[0] = _N[index]
    out[1] = _E[index]
    out[2] = _S[index]
    out[3] = _W[index]


cdef class Board:
    def __init__(self):
        for i in range(368):
            self.vertices[i] = 0 if i < 361 else -1
            self.next_vertex[i] = i

        self.zobrist_hash = 0

        # forbid the empty board state for occuring again
        for i in range(8):  # len(self.zobrist_hashes)
            self.zobrist_hashes[i] = 0
        self.zobrist_hashes_index = 0

    cpdef Board copy(self):
        """ Returns a copy of this board. """

        cdef int i

        other = Board()

        for i in range(368):
            other.vertices[i] = self.vertices[i]
            other.next_vertex[i] = self.next_vertex[i]

        other.zobrist_hash = self.zobrist_hash
        other.zobrist_hashes_index = self.zobrist_hashes_index

        for i in range(8):
            other.zobrist_hashes[i] = self.zobrist_hashes[i]

        return other

    cdef int _has_one_liberty(self, int index) nogil:
        """ Returns a non-zero value if the group that the given vertex belongs
        to has **at least** one liberty. """
        cdef int starting_point = index
        cdef int[4] ns
        cdef int n

        while True:
            # check each candidate liberty to see if it is a liberty 
            neighbours(index, ns)
            for n in ns:
                if self.vertices[n] == 0:
                    return 1

            # step forward
            index = self.next_vertex[index]
            if starting_point == index:
                break

        return 0

    cdef int _has_two_liberty(self, int index) nogil:
        """ Returns a non-zero value if the group that the given vertex belongs
        to has **at least** two liberties. """
        cdef int starting_point = index
        cdef int other_liberty = -1
        cdef int[4] ns

        while True:
            # check each candidate liberty to see if it is a liberty 
            neighbours(index, ns)
            for n in ns:
                if self.vertices[n] == 0 and n != other_liberty:
                    if other_liberty == -1:
                        other_liberty = n
                    else:
                        return 1

            # step forward
            index = self.next_vertex[index]
            if starting_point == index:
                break

        return 0

    cdef unsigned long _capture_ko(self, int index) nogil:
        """ Returns the necessary adjustment to the zobrist hash for the current
        board state if the group that the stone with the given index belongs
        to was captured. """
        cdef int starting_point = index
        cdef unsigned long zobrist_hash = 0
        cdef int[4] ns

        while True:
            zobrist_hash ^= ZOBRIST[361 * self.vertices[index] + index]

            # step forward
            index = self.next_vertex[index]
            if starting_point == index:
                break

        return zobrist_hash

    cdef int _is_valid(self, int color, int index) nogil:
        """ Returns a non-zero value if playing a stone at the given vertex is
        a valid move for the player `color`. """

        # check if the vertex is already occupied
        if self.vertices[index] != 0:
            return 0

        # check if the vertex has at least one direct liberty, in which case it
        # is always a valid move
        cdef int[4] ns

        neighbours(index, ns)
        for n in ns:
            if self.vertices[n] == 0:
                return 1

        # check if the playing in this vertex capture any of the opponents
        # groups, or if it connects to a group with at least two liberties.
        cdef int other = opposite(color)

        for n in ns:
            if self.vertices[n] == other and not self._has_two_liberty(n):
                return 1
            elif self.vertices[n] == color and self._has_two_liberty(n):
                return 1

        # no direct liberties, and it does not create any liberties by capturing
        # a group. It is suicide :'(
        return 0

    cdef int _is_ko(self, int color, int index) nogil:
        """ Returns a non-zero value if playing a stone at the given vertex
        gives rise to a board state that has already been encountered. This
        function assume that the given move is valid according to `_is_valid`
        and will give back non-sense if this is not true.
        """

        # place the stone on the board
        cdef unsigned long zobrist_hash = self.zobrist_hash
        zobrist_hash ^= ZOBRIST[361 * color + index]

        # capture any of the opponent groups
        cdef int other = opposite(color)
        cdef int[4] ns
        cdef int n

        neighbours(index, ns)
        for n in ns:
            if self.vertices[n] == other and not self._has_two_liberty(n):
                zobrist_hash ^= self._capture_ko(n)

        # check if the acquired board state is listed as forbidden due to
        # the super-ko rule
        for forbidden_hash in self.zobrist_hashes:
            if zobrist_hash == forbidden_hash:
                return 1

        return 0

    cpdef int is_valid(self, int color, int x, int y):
        """ Returns a non-zero value if playing a stone at the given vertex is
        a valid move for the player `color`. """

        index = 19 * y + x

        return self._is_valid(color, index) and not self._is_ko(color, index)

    cdef void _capture(self, int index) nogil:
        """ Remove the group that the stone at the given index belongs to from
        the board. """
        cdef int starting_point = index
        cdef int[4] ns
        cdef int n

        while True:
            self.zobrist_hash ^= ZOBRIST[361 * self.vertices[index] + index]
            self.vertices[index] = 0

            # step forward
            index = self.next_vertex[index]
            if starting_point == index:
                break

    cdef void _connect_with(self, int index, int other) nogil:
        """ Connect the chains that the given vertices belongs to into one
        chain. If the two vertices belongs to the same chain then it does
        nothing. """

        cdef int starting_point = index

        while True:
            if index == other:
                return

            # step forward
            index = self.next_vertex[index]
            if starting_point == index:
                break

        # re-connect the two lists so if we have two chains `A` and `B`:
        # 
        #   A:  a -> b -> c -> a
        #   B:  1 -> 2 -> 3 -> 1
        # 
        # then the final new chain will be:
        # 
        #   a -> 2 -> 3 -> 1 -> b -> c -> a
        # 
        cdef int index_prev = self.next_vertex[index]
        cdef int other_prev = self.next_vertex[other]

        self.next_vertex[other] = index_prev
        self.next_vertex[index] = other_prev

    cdef void _place(self, int color, int index) nogil:
        """ Place a stone that belongs to player `color` on the given vertex.
        This function assume that the given move is valid according to the
        `_is_valid` function. """

        self.vertices[index] = color
        self.next_vertex[index] = index
        self.zobrist_hash ^= ZOBRIST[361 * color + index]

        # capture any of the opponent stones that does not have any liberties
        cdef int other = opposite(color)
        cdef int[4] ns
        cdef int n

        neighbours(index, ns)
        for n in ns:
            if self.vertices[n] == other and not self._has_one_liberty(n):
                self._capture(n)
            elif self.vertices[n] == color:
                self._connect_with(index, n)

        # add this board state to the set of forbidden states (super-ko)
        self.zobrist_hashes[self.zobrist_hashes_index] = self.zobrist_hash
        self.zobrist_hashes_index += 1

        if self.zobrist_hashes_index >= 8:  # len(self.zobrist_hashes)
            self.zobrist_hashes_index = 0

    cpdef void place(self, int color, int x, int y):
        """ Place a stone that belongs to player `color` on the given vertex.
        This function assume that the given move is valid according to the
        `is_valid` function. """

        self._place(color, 19 * y + x)

    cdef int _get_pattern_code(self, int color, int index) nogil:
        """ Returns the 2-bit pattern of the vertex at the given
        index (normalized to the given color). """

        cdef int other = opposite(color)

        if self.vertices[index] == 0:
            return 0
        elif self.vertices[index] == color:
            return 1
        elif self.vertices[index] == other:
            return 2
        else:
            return 3

    cdef int _get_pattern(self, int color, int index) nogil:
        """ Return the 2-width diamond pattern around the given `index`,
        normalized so that the given `color` is the current player. """

        cdef int pattern = 0

        pattern |= self._get_pattern_code(color,    _N[index] ) << 16
        pattern |= self._get_pattern_code(color, _N[_E[index]]) << 14
        pattern |= self._get_pattern_code(color,    _E[index] ) << 12
        pattern |= self._get_pattern_code(color, _S[_E[index]]) << 10
        pattern |= self._get_pattern_code(color,    _S[index] ) <<  8
        pattern |= self._get_pattern_code(color, _S[_W[index]]) <<  6
        pattern |= self._get_pattern_code(color,    _W[index] ) <<  4
        pattern |= self._get_pattern_code(color, _N[_W[index]]) <<  2
        pattern |= self._get_pattern_code(color,       index  ) <<  0

        return pattern

    cpdef int get_pattern(self, int color, int x, int y):
        """ Return the 3x3 pattern around the given `index`, normalized so that
        the given `color` is the current player. """

        return self._get_pattern(color, 19 * y + x)

    cdef int _get_num_liberties(self, int index) nogil:
        """ Returns the total number of liberties that the group the given
        index belongs to has. """
        cdef char visited[362];
        cdef int starting_index = index;
        cdef int count = 0
        cdef int[4] ns
        cdef int n

        for i in range(361):
            visited[i] = 0
        visited[361] = 1

        while True:
            neighbours(index, ns)
            for n in ns:
                if self.vertices[n] == 0 and visited[n] == 0:
                    visited[n] = 1
                    count += 1

            index = self.next_vertex[index]
            if index == starting_index:
                break

        return count

# -------- Code Generation --------

cdef int *_N = [
     19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,
     33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,
     47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,
     61,  62,  63,  64,  65,  66,  67,  68,  69,  70,  71,  72,  73,  74,
     75,  76,  77,  78,  79,  80,  81,  82,  83,  84,  85,  86,  87,  88,
     89,  90,  91,  92,  93,  94,  95,  96,  97,  98,  99, 100, 101, 102,
    103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116,
    117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130,
    131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144,
    145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158,
    159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172,
    173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186,
    187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199, 200,
    201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214,
    215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228,
    229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242,
    243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 256,
    257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270,
    271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283, 284,
    285, 286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298,
    299, 300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311, 312,
    313, 314, 315, 316, 317, 318, 319, 320, 321, 322, 323, 324, 325, 326,
    327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340,
    341, 342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352, 353, 354,
    355, 356, 357, 358, 359, 360, 361, 361, 361, 361, 361, 361, 361, 361,
    361, 361, 361, 361, 361, 361, 361, 361, 361, 361, 361, 361
]

cdef int *_E = [
      1,   2,   3,   4,   5,   6,   7,   8,   9,  10,  11,  12,  13,  14,
     15,  16,  17,  18, 361,  20,  21,  22,  23,  24,  25,  26,  27,  28,
     29,  30,  31,  32,  33,  34,  35,  36,  37, 361,  39,  40,  41,  42,
     43,  44,  45,  46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,
    361,  58,  59,  60,  61,  62,  63,  64,  65,  66,  67,  68,  69,  70,
     71,  72,  73,  74,  75, 361,  77,  78,  79,  80,  81,  82,  83,  84,
     85,  86,  87,  88,  89,  90,  91,  92,  93,  94, 361,  96,  97,  98,
     99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112,
    113, 361, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126,
    127, 128, 129, 130, 131, 132, 361, 134, 135, 136, 137, 138, 139, 140,
    141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 361, 153, 154,
    155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168,
    169, 170, 361, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182,
    183, 184, 185, 186, 187, 188, 189, 361, 191, 192, 193, 194, 195, 196,
    197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 361, 210,
    211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224,
    225, 226, 227, 361, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238,
    239, 240, 241, 242, 243, 244, 245, 246, 361, 248, 249, 250, 251, 252,
    253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 361,
    267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280,
    281, 282, 283, 284, 361, 286, 287, 288, 289, 290, 291, 292, 293, 294,
    295, 296, 297, 298, 299, 300, 301, 302, 303, 361, 305, 306, 307, 308,
    309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320, 321, 322,
    361, 324, 325, 326, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336,
    337, 338, 339, 340, 341, 361, 343, 344, 345, 346, 347, 348, 349, 350,
    351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 361
]

cdef int *_S = [
    361, 361, 361, 361, 361, 361, 361, 361, 361, 361, 361, 361, 361, 361,
    361, 361, 361, 361, 361,   0,   1,   2,   3,   4,   5,   6,   7,   8,
      9,  10,  11,  12,  13,  14,  15,  16,  17,  18,  19,  20,  21,  22,
     23,  24,  25,  26,  27,  28,  29,  30,  31,  32,  33,  34,  35,  36,
     37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,
     51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,
     65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,
     79,  80,  81,  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,  92,
     93,  94,  95,  96,  97,  98,  99, 100, 101, 102, 103, 104, 105, 106,
    107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120,
    121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134,
    135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148,
    149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162,
    163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176,
    177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190,
    191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204,
    205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218,
    219, 220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232,
    233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246,
    247, 248, 249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260,
    261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274,
    275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287, 288,
    289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302,
    303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314, 315, 316,
    317, 318, 319, 320, 321, 322, 323, 324, 325, 326, 327, 328, 329, 330,
    331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341, 361
]

cdef int *_W = [
    361,   0,   1,   2,   3,   4,   5,   6,   7,   8,   9,  10,  11,  12,
     13,  14,  15,  16,  17, 361,  19,  20,  21,  22,  23,  24,  25,  26,
     27,  28,  29,  30,  31,  32,  33,  34,  35,  36, 361,  38,  39,  40,
     41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  51,  52,  53,  54,
     55, 361,  57,  58,  59,  60,  61,  62,  63,  64,  65,  66,  67,  68,
     69,  70,  71,  72,  73,  74, 361,  76,  77,  78,  79,  80,  81,  82,
     83,  84,  85,  86,  87,  88,  89,  90,  91,  92,  93, 361,  95,  96,
     97,  98,  99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
    111, 112, 361, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124,
    125, 126, 127, 128, 129, 130, 131, 361, 133, 134, 135, 136, 137, 138,
    139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 361, 152,
    153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166,
    167, 168, 169, 361, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180,
    181, 182, 183, 184, 185, 186, 187, 188, 361, 190, 191, 192, 193, 194,
    195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 361,
    209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222,
    223, 224, 225, 226, 361, 228, 229, 230, 231, 232, 233, 234, 235, 236,
    237, 238, 239, 240, 241, 242, 243, 244, 245, 361, 247, 248, 249, 250,
    251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264,
    361, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278,
    279, 280, 281, 282, 283, 361, 285, 286, 287, 288, 289, 290, 291, 292,
    293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 361, 304, 305, 306,
    307, 308, 309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320,
    321, 361, 323, 324, 325, 326, 327, 328, 329, 330, 331, 332, 333, 334,
    335, 336, 337, 338, 339, 340, 361, 342, 343, 344, 345, 346, 347, 348,
    349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 361
]


cdef unsigned long *ZOBRIST = [
    0x59c80c3f4f4e843e, 0x5fd4c53fc8018e16, 0x38feebce745f56cf, 0xaec0e024a87ed080, 
    0x929a41160e924f13, 0x3668f7c195495fe7, 0x7cc1596324b95cd7, 0x382422bcd5bd7c43, 
    0x6eb408e4065cd007, 0x8bd87584809f21af, 0x4f35eb343ded5dde, 0x29ca85eea5225fa7, 
    0xc3f338d3f943b76e, 0xc7623756008346ad, 0x77f41b3d0e4de8c3, 0x5e5f22332646b18f, 
    0x6619c8eee5aac6af, 0xc982afda6c6faa7c, 0x8f92582cd3720b96, 0x6386ebf020e1fe20, 
    0x4d840d6b1dfb4eb2, 0xf85df5faeddc9581, 0x4eb95f14bf3831cf, 0x893b014b01cad7fb, 
    0x637ef1b9a208266b, 0xcfa65ac6ee52fc57, 0x8a714bcfd9cdce07, 0x9717a976615beb1a, 
    0xbe18164683926576, 0x124ca78b9b993847, 0xc979266dc228650a, 0x805a8c3318a73e09, 
    0xe78c838a6c14e97d, 0x71bb0ed8d43329aa, 0x7eb3574da357265f, 0x91e0d8bec2c05639, 
    0xfa018227ef4f3bc5, 0x998ed83d2241aec6, 0xa03c2a3d655538ca, 0xe0eb212f4d7f9ced, 
    0x52068b2d6cae721b, 0xbc82a88659ea25b7, 0x82e1d6c07e616736, 0xa93c65369dd37087, 
    0xda770019929633fc, 0x0f88d45ba9d1c4ed, 0x2ad40fdadc61b8c9, 0xdc86384734c09289, 
    0x5900a6c741b9940e, 0x93d4e0a1f0d73eeb, 0x3ea19db5576ea617, 0xe1c9e6d17e3dc5e7, 
    0x025e643fab41d2b5, 0x08cc40b8eb8b4881, 0xfd15a82c2f936443, 0x9bee3763f503398a, 
    0x6defe41fbb035d83, 0x0baa614cb3db53be, 0xb9fd6f4e929b728a, 0x30652b51074736d5, 
    0x9ba8efe765b3c679, 0x2938ff484c8e21be, 0x1df7c0571b353734, 0xb55ce62d9f7fc1fb, 
    0xfad5d85bed40f779, 0xcc78a9ac7700ec86, 0xe46196605f12b4a5, 0xa3007f066a18bda5, 
    0xe0cc625a49f055e6, 0x2e4c4f5cfdf7158f, 0x6d7f09ca720f690a, 0xcebdc44b34dd1011, 
    0x333fa7eb6c99e252, 0x5ea34d1db902ef67, 0x237d4f528f5de603, 0xcdb26ca6c9d12254, 
    0xc8959749b1095e30, 0x052a30144b00aecd, 0x32373e0b45f18255, 0xdb28b6baa446d6f4, 
    0xe6c2a91d018c9da7, 0xd366b079f04f70d5, 0xf9c11d5b43f1a8b8, 0x68d05e24b07f043e, 
    0x723b55e517d8207b, 0xf21ab83f1b7e68c5, 0x20a815f099ba7777, 0x2eb9657201cc3222, 
    0x0ffbecc5aef05150, 0x0d315de919c58895, 0x48f5845380653a6e, 0x296800995e296fd5, 
    0xf124dc4dc08bf919, 0x800e59b9e2a80370, 0x372a3190c9afeee9, 0x719ea794cd4201fe, 
    0x137b168664d14dfa, 0x9ba3f770b7c7cd29, 0xaa2b9b4ea5858a4c, 0x0cd4ed14c3f9b89c, 
    0x0106d5e5c557580b, 0xecf15152ac3d60e7, 0x1a861dd54ba2e14b, 0x19a09381de3266f7, 
    0xbaaa45f3343c4a83, 0x37757636aadfcecc, 0x7c2f0d5ce077a470, 0x88a19cdc7a9b5e6c, 
    0xa1db502c76a2e57b, 0x39ed6bd773b46355, 0x50b36ee4661cf215, 0xe1bfd79e3630eebb, 
    0x7abf9598d8f69c52, 0xeb4ed14068ef42ec, 0x59882494c8e30926, 0xe94d36d13ef60a94, 
    0x44679c1d910ad988, 0xf3e696804d8c2189, 0xe4e47611ea9e7da9, 0xdeba131209e5ddf6, 
    0xfb6a4ff1087b57fb, 0xc0121d95b26009a0, 0x2fd5f0e58367d816, 0xb086537660729f61, 
    0x8db95c2a5d9ee810, 0xe56b1d95fa44b462, 0x98dc0660a24563f7, 0x5c139f51b52de9ca, 
    0xf02b76a48e0a77fd, 0xe9389027769711dc, 0xf857448bb63bb105, 0x238dc07f64be0ed7, 
    0x4b3c9caf707afc47, 0x1d3f73db2f0b68b0, 0xfcdde67c246ea4f1, 0xb3da12f64b527a30, 
    0x636ecd76c9478fd8, 0xf02254b7d065d495, 0x70016a2e60c2c571, 0xea18b34b60493c2f, 
    0x6ae33f179d84b185, 0x55ee6c1bfcd44d6a, 0x4d296a9cf00f1ffd, 0xea3d04ee7ab21fca, 
    0xbf3561179a344f48, 0x75607b27dbfc488f, 0xf68d80d4be559e90, 0x5aed9c24c478e72d, 
    0xed50f4ed718a461b, 0x4bd735abe05bd81e, 0x8cf4740ae23ece46, 0x87fc41aa0c466a94, 
    0xbf6ac917a159da2a, 0x220ef60a25b59b01, 0xca9edee4ca5bc685, 0x427ba7090e93b670, 
    0x15151f14fa7719a0, 0xb1e352c20990a450, 0xd5662f69aa635da8, 0xe321e08216d3d06e, 
    0x9b6220867d618687, 0xadb9db7083fe4252, 0xf7718d9fcfbd3bfd, 0x70c42332efa36d9b, 
    0x6a7a48ded08c6ce4, 0xda7676c8adf9f425, 0xe68086d16121d17b, 0x2c9de79bfbd7e6ad, 
    0x276d2edaa291c1e4, 0xe99834abad6404a1, 0x81e3202e307a5ab4, 0x46308332670b4a0a, 
    0xc0a7bacd54367687, 0x770d3627b7d399c7, 0x7b6246f7c8f52522, 0xfe8ae97bc6b69084, 
    0xdcde80ebc7fe8f0f, 0x97eef0201d2c6ae6, 0x44385ff7a63a6dcd, 0xb907673f8d754088, 
    0x81b871f526a9f269, 0x55f3bcf6f74f2679, 0xde2e0ecafc06d399, 0xe023943892fff475, 
    0x6cd3558896e816b1, 0xfa9cddb58a1f760d, 0x2560a2d067c9777f, 0x64e1b1bed7e144ee, 
    0xecaa1d5f77f2e2bd, 0xc4743e644873dcc0, 0x74294211258b7fcb, 0xce5951ddbf97f1e3, 
    0x73cb92c7c25a82b9, 0x996f43027868c1d3, 0x107ee3072da29024, 0xd5b3999259da4c40, 
    0x9f69308cffd24f92, 0x91c0e5a4fcf11dc7, 0x139c116a5c1f7a88, 0xed5eba6c862efe49, 
    0xdcaf10774d62a70d, 0x31fcccdb571ee58d, 0x5e5038838b471aed, 0xc9d9f20b4cf5d3d2, 
    0x96b136227aac4236, 0xd80a360ce42ff651, 0x51a6ae88e43dac8b, 0x0c972a9f83020863, 
    0xde1243a322b0d075, 0x96786b56d6b64263, 0x37e43ba297aa5d91, 0x705123b74a33b6b0, 
    0xbce3531c9fe36b94, 0x3bb786bd4d86af0a, 0x6292780a7d7e3f7a, 0x39843985ba6f497e, 
    0xcbf7f9a75060b535, 0x1017031013bd04b6, 0xca33971648d12050, 0xb6e7efa9cdc982d7, 
    0xf424d14f16a15206, 0x0b73efb6d0b412d9, 0xaa3b583a480efe46, 0xc7e0ab73752d5cac, 
    0x36febedc59117cb1, 0x828f4be1823e1a15, 0x5974e451f508bf21, 0x9d51fbe73d7c8833, 
    0x180704547ed3353f, 0xf5234512c5a326cc, 0x63f07356b9596d43, 0xcdac6a9d8053d9cc, 
    0xb2105a44b455f2cd, 0xc9aaa372d016084b, 0x6054177d5f28a85f, 0x6497e9411ecc5717, 
    0x039fb8682e31b549, 0x9456cd5632638a7f, 0x4a91d9e333eb0654, 0xe7f7204c26a6a4f6, 
    0xd0a51219cc8c524a, 0x36cdfef6a343966a, 0x0c1491a54dc91fae, 0x85d40c43408d29ff, 
    0x04e0418eee27857a, 0x2342f3e04ec6e2d3, 0xd2d15a5dac7a710b, 0x56fba8ecfd85f0fe, 
    0xd6907f4a99e02ba1, 0x97229e0f0221fc53, 0xa424e90eb5cf5758, 0x137ff5e855e83a80, 
    0x86c1c1193d83870c, 0x53a3d8b87f32e754, 0x7fe381945432c751, 0xc19ddcfd5faa3d10, 
    0xa37974abc3ae53d5, 0x2d9adf38209e8b98, 0x03cc65da3f77dd26, 0x5460a494ae104710, 
    0x07335ce48ffc9b73, 0x1f262f20030ad4c9, 0xb15473f80157134c, 0x07015869e0203f2b, 
    0x3c732ae16fdb5094, 0x75411f02894a1c2c, 0x2fd43b288e5b5709, 0x204815c5de2351e3, 
    0xb341eb9f1bd75be7, 0xfd37b8423c2b0af3, 0x96fabf50a8dbadc6, 0x69dab8a0d79e4945, 
    0x8cedba297c73bffe, 0xbd9eeb0877eac386, 0xb10e0cae591da1a9, 0x50d4c2280c488a56, 
    0x591623eda8a8c362, 0xe9c22581caefc20f, 0x5ca80b9f585bd328, 0x73f92898708e0ea1, 
    0x261212071d4bd524, 0x9cc0131477eb9d71, 0x6bfcee315c1b9780, 0xfc1c7ff4adfe47b6, 
    0x567da7bd664ceb81, 0x457a15809098cde2, 0x8093f951ec76224b, 0x3ea55719de75d277, 
    0x081e211d71de733a, 0x0e74f9688568b098, 0x3d11fc9b1550a4e8, 0x8bb11761e897d5fa, 
    0x8a8b1f22b7df738a, 0x8230fcfc14a793de, 0x8f75e5aafbc3b5b4, 0x5c3621f0ad3b9531, 
    0xaf64d3097d887237, 0x25211dc68d185d07, 0x1bed3fd897e5f2bc, 0xbfd172ea0ecd5459, 
    0xa6304b481ddff0c0, 0x8994749a14a21fbd, 0x7b576f2bb2b8f41f, 0xf253f906841292ca, 
    0x858fcce5a3231e53, 0xeb9d26e70f20d622, 0x155195576f4c849b, 0x25d5b3ae6c2da721, 
    0x90b324b885a8ae99, 0x7e10a6db29ff8c00, 0x173aeeafd102b513, 0xefa69199efb7f29b, 
    0x55d6c4755df4ebdf, 0x7474aded1cfcdfe1, 0x1cf68ff849dbcedb, 0x3366ca37ef042ee6, 
    0x9f66572c0726a54f, 0xc5c49b50ee14675c, 0xc575c6d8269d8dc0, 0x101f9d4b22a8c6f7, 
    0xcf6a2ef436731bd0, 0x51e8b9f89bb8ad24, 0x45d6440cc0017152, 0xdbe4c79d98959f6a, 
    0xcfcb35c87e595153, 0x3cf3e2f8561908e2, 0xc74ad4368e296cce, 0x50a7cfe77f296448, 
    0xbba1e87eeeaeebb1, 0x8f1bcdce6b930f5d, 0x34662705ee94bd1b, 0x8610134fe2e7f72d, 
    0x03ef0eec91245b1f, 0x0c277be777da6350, 0x5f56cfecd51e53dc, 0xbbbf08d7dfe8ff1b, 
    0x4443b69f3b77515a, 0xb1c8a7bd1bf0c120, 0x29b54d182e1fadc4, 0xacba3a4de75d4d45, 
    0xdd0de276b742b33c, 0xc170855ed6c429c7, 0xbfe57904a8ef8eb7, 0xd96f1072922af6cb, 
    0x3bb150e7970c2b1d, 0xda9b9bf25b1b3ea2, 0x16d9dfb5786401a0, 0x07ddeea0288e0191, 
    0x63165b833e880210, 0x4861ac9b45385ecc, 0x8c9ddbd050cda125, 0x41bdb7102923de88, 
    0x916514e91601e811, 0x514035a7b1f0cad7, 0x6dc987b86c760f58, 0x5281b2d9dd559fec, 
    0xca73f84c2a962247, 0x2f19269da704236b, 0xb2a0de56efdb0037, 0x40869004195d761d, 
    0x8b1359b464182e6c,

    0x7256053218689ba0, 0xb6e70d9ebdff81a1, 0x99882edd9faa855b, 0x75bfa5e26bf9cbff, 
    0xd3b5f6ebb93f1a46, 0xfe1a56148188ee0e, 0xb0bd4ee7e3278ac5, 0x780672e4e35734db, 
    0x5ad64fa64c60341a, 0xef83f9f28872f3e5, 0x262747dd993095c9, 0x576af960a99199ae, 
    0xd755005c9ec43d23, 0xa22341351ea36b22, 0xa9eb13f540f23ad3, 0x97e889a578fb4e00, 
    0x240e509d83892861, 0x48956b94f1a3d7c0, 0x4806b483cdb7bea6, 0xc14357784ac1d729, 
    0x9fce37dfb441faa7, 0x76ad6b10e32373a2, 0x09aca2435c8b29b2, 0x9d0f1b7943a2ac27, 
    0xdd309c8c5c36a1c6, 0x03669e51fda0ac01, 0xeea56f1b9a9d3ce3, 0xce105fd1cd372874, 
    0x34be85e2297e8876, 0xe83d7ae223268f55, 0xb8853fb325142e15, 0x480bcebba5fe6e69, 
    0x77072920254bcad0, 0xb477b1de0b9367f8, 0xbcdcf6cf9708b84d, 0x1d714ada3ff52470, 
    0x009001625cd993d4, 0x850f2b7606199c0b, 0xc7751f193334b016, 0xf755666eff7b143d, 
    0xd7c78e480e180373, 0x8223cb279ef055bc, 0x415aec56608d7668, 0x972af1bcaa878da3, 
    0xd18110dfc0996c6a, 0x19db68e9dd3a882e, 0xecf75517082e7485, 0xe500338a63b4d1d3, 
    0xd87039fa81a21fff, 0x88bd7d550cdb26eb, 0xbf90e88d951fb942, 0xb900e899039f273e, 
    0x7fa971750ef837ba, 0x34366381b7c186c2, 0x239445f74f4ef83e, 0x270dca6f37871285, 
    0x0bb0ddefb80cf151, 0x0e0a9b6f225a2d53, 0x0d2b6e47a7890104, 0x6cd15769c8ac1fa7, 
    0x2981471876564270, 0xe21f945b21efad42, 0x9b1764af8d6122d7, 0x2c634ecc7fa70780, 
    0x922a11d3306aa760, 0x3264cbf34e462e6f, 0xfa464577d4f35b5f, 0xe8007f8d3d00e26a, 
    0xba9710e2f6fba141, 0xb13682b27bcc27bc, 0x5de251d35ff59c87, 0xb9657801fab4714e, 
    0x7a1d7540cfdc385a, 0xec3b73ca9901fb00, 0x88a69dea80aeacef, 0xcf85bbc6a3c9983d, 
    0x89c6686bb72765c0, 0x5461c3b9fd52f6ab, 0x40e7a4929fbe58b3, 0x47427ef778ce61e5, 
    0x56fcafefefb5838e, 0xac5e0096e3f69c26, 0xbc71ff4c30ad4346, 0x4df1c4816f23f52c, 
    0x104dee7ab58410d4, 0x48d7d72d5dc953c4, 0x5083e443b7961482, 0x270e20fcb91e3749, 
    0x89b9f5033fe9a229, 0x12712555988bb420, 0x686b3eec7d179061, 0xa4644f794f59e72c, 
    0xf79973181284a0b8, 0x0e885c46e1697e22, 0x17f85685c1ff195a, 0xa11af9e634f191f6, 
    0xe0de0b46823fd902, 0xbb5ad7e9b69fecb3, 0x7780fac85ad51033, 0x1f7c06b9994016d8, 
    0x7b620d71e4946731, 0xe2314b63918aa0be, 0x467961d306a1f73a, 0x4370943ad8210be4, 
    0xc32a17dac2506ac1, 0x2157a7edce3103ee, 0x1c6aab212af99413, 0x475f5c397cb0f66b, 
    0xcf61cb202e03a12b, 0x5dadb9b3eb7b3a73, 0xf5bde2ebca6fa3d0, 0x7d48c0bf8104c44e, 
    0x60744819abac38d2, 0xeae001bccbafce93, 0x18e82bdab5cec6ba, 0xce28a917035c7286, 
    0x5e4481392a533708, 0xe400cab96116a2a3, 0x72ea86e509d7902e, 0x9774f0ae2850bbd0, 
    0x90e3c1d7f8c49ffa, 0x041fea78ec29d5ea, 0xe5723a8f393e59ae, 0x7060718cf900eee1, 
    0x85f9b022c5c1b6ad, 0x39aedb19114a522f, 0xb581eb637778e628, 0xab9450b77b16a305, 
    0x83c333edd3dd9c3b, 0xd2a6ad0f6454ba03, 0xcba20071de776680, 0xbb9194a0f080efc3, 
    0xb96a8e49f7949905, 0x7392c291aa22b188, 0xc858e8c246d8ec7f, 0x41851f0d518eff14, 
    0x550ec6dbcd9ccad4, 0x0eb81cca0246b9eb, 0xdb2c8245f41d846a, 0xaa501cf9094ee351, 
    0xe7c55263614362e4, 0xaabddba753b0a331, 0x0639a9302f649f29, 0xe21e7113ad6164f0, 
    0x4003c4f8ed409166, 0x2458b930efbd20a5, 0x73ef7a378f00fb8b, 0xb21c08966932c345, 
    0x3605722ab34895ee, 0x5c7761723ee8560e, 0x4171162bb675839a, 0xb4305b57fc3e7e7a, 
    0x982d519f983fdd43, 0x3b5f408b22af71ec, 0x3011376a4b9aa11e, 0xc329694a8692b30b, 
    0x3aadabbaff6ca1b5, 0x1f14a718c468f3b2, 0x16b0cd9ae06be6da, 0x94ca8e2e1aa9b443, 
    0xdf5352b5351f6ec0, 0x17eea2a732044472, 0x8abb333a1ad6b204, 0xfba06f1fcf46fa02, 
    0x8ce8bbd6c308425b, 0x3d3d3b548c1cca60, 0x030a773886494b97, 0x0bf8836caf188f54, 
    0x752121b85190194e, 0xfee0182a14bde45c, 0x940462eb65d03e84, 0x7c5457f57acecc5d, 
    0x0a32dd8bb183e162, 0xfb91e3727414338f, 0x3456c97686c7a0c9, 0x39d19fdb465619c5, 
    0x3061098bb4ac0954, 0x73a02a671d2ef5f3, 0x335d7c7597beea9a, 0x5dab16b7ac73f866, 
    0xed21bb5df4976a58, 0x16fc44e22bb79999, 0xb0416e506cafc841, 0xae02a45fbf92fea9, 
    0xc41f9c9d52fd4656, 0xeb3ada4b126c209f, 0xacfd94070e83f85f, 0x4080f63995e330a2, 
    0xebd676479a42cc29, 0xb828fffe999ea892, 0x16239d2d38471209, 0xbdd6e96228f265c7, 
    0xda3eab91a736380a, 0x0553a025f7807a3d, 0x2da590e00569a84e, 0xedf196e9ec6e93bb, 
    0x72fb1ed0669c2e8a, 0xfa2f4c464bfc4f23, 0xf440c23fe4820577, 0x1c5087134240038a, 
    0x06b8714080342bcb, 0xb70e6db7d0700f1c, 0xb11e67d10ca4a793, 0x7c42c67ffeb3a694, 
    0x6fe9daabddc8354e, 0x114937df81c5237a, 0x3a5d1a1bf0c901bd, 0xfb384beac3046c95, 
    0xc2e6fe6db57a66d1, 0x9c0d4914109d27a7, 0x64b7347ea814975d, 0xd38415a5c4e94154, 
    0xac5cc2efb6ae5ef7, 0x1aee1f196a20340b, 0xfc873162fd266108, 0x2f61b49fa4875f16, 
    0x6ec52083a4b2d260, 0xf52418cbb27949ee, 0x524465be4bcfe0bb, 0x62a1a18ad8e6cb7d, 
    0x52bd58c0c4ba5216, 0xcb52f3213bb85d1a, 0x6048af98aad9438c, 0x409626c75fe7127c, 
    0x6868605d38f1d3c0, 0xf7520b6d85e6d471, 0xb4035fe827473f59, 0x83035dc8a9f6b6e8, 
    0x5f78ed8952ac2b63, 0x67a968ac619feb49, 0xe4d571503fc920df, 0x075ffba3d4b9f4b5, 
    0x3806d0cda284a9db, 0x1fc43e730f9a21ab, 0x3488eafec32e4d27, 0x309480d1358ea701, 
    0x3a6afb25183c9ca2, 0x44c1cd2acd62c128, 0xc50e902b9088172f, 0x6eab0571f9da822f, 
    0x4e5a6f03b3c85368, 0xd651efbcae067c43, 0xadb5144c8700e8b5, 0x58513545d088dc24, 
    0x0951cce798e5d9aa, 0xde52e20ce761aeb9, 0x72ed64be8d970d00, 0xb84aed99d096ee3a, 
    0xbff774b22d90e9d3, 0xf1cfae90402f9b03, 0x142c9502d961732e, 0x595a3ed492b3447d, 
    0x6e8c64a229287e9d, 0x9f0118a809c484f6, 0xdbfe68784d0c8369, 0xa324f6979bb5142d, 
    0xbbc4d6e79a028322, 0xcf611a166997c145, 0x16bee24b49941bf5, 0xb6a4d785ea533d99, 
    0xb13c094f428b197e, 0x23852a12c0b2e0f1, 0xe37fcc7cdee725a3, 0x1f74b14bc9144c48, 
    0x18a7b2b54389b046, 0x11ce4b22abcbec24, 0xf4b537c25b79b5d2, 0x49aa13a619488827, 
    0x60a4cb4e60872b6a, 0x2429cbb600794d4b, 0xbf32e99dce39ae89, 0xa81639025a148085, 
    0xb1ac1ab5fdf6263f, 0x53df2010a6999845, 0xb78dbebe8869106f, 0xbc2167de901d0e6c, 
    0x53ae03ed69294859, 0xf314ec4bbba81d23, 0xee5bf6de99622e8d, 0x66aab3a51d549db9, 
    0x0acfc0d264580f18, 0x39a94816c5d13a1d, 0x2a67c30b7700413f, 0x56f9ebdbb8519d2b, 
    0x7850f05866524eca, 0xf3fbc2952d47035e, 0x10dae94914f528e3, 0xa5f9a7b1dd25a6d8, 
    0xecc98de659e3cf99, 0xf54d1b44fddc3993, 0xda0b075ebe318bbb, 0x25d0530bd92efab2, 
    0x131f2af1fcda7846, 0x17497834377b00d5, 0xacc7ed1ace74fb99, 0x817a53be0a9a1508, 
    0x347cf55e46cad69c, 0x1b8fc5234297ab71, 0x51ca2dfeb98f2c0f, 0x328c34c17d0050ef, 
    0x1d5ed4147464c1fa, 0x56a1a1fb6cc5e87e, 0xfcad04a42aba8875, 0xbfdac171eb68a476, 
    0xa6f2e77883d620c8, 0x7411888eb9da3fb7, 0x8bb894f4050ca25b, 0x1d0098ed5506e105, 
    0x08badb32e68d8cf4, 0x159e552b75454772, 0x7850dbacc3a91ade, 0xf67ff6dcf0b315d2, 
    0x63f73c416988a05e, 0x916d7285d8fa0fea, 0x41a4a3a96684b599, 0xa634e23a2acd4288, 
    0x58db2471cdbd987a, 0x26f2d3866aa1938e, 0xa1adace7cf00a6bc, 0x942e9ecc116ecdad, 
    0xc2368d2c8967abd5, 0x47e342f59a05b62c, 0x899a7dca75f5b4ca, 0xd99777bdd7e1d47b, 
    0x475af77ddfaa1574, 0x94345ae6d0bd39bc, 0xad1f7512904210ef, 0x91172bcc3ff2a0f8, 
    0x76d4f656896f6557, 0x4134a86ddb82ac76, 0x1e921111ad89b6d8, 0x9d25a653048a0a7d, 
    0x6d3ace7635b5a81d, 0xb549f52251831adf, 0xb635e4971a4312eb, 0x960a071d32848a80, 
    0xf290dd9c7bc28c9a, 0xc723a55f7c2093e7, 0x40e304ece6c91065, 0xa340770c075d3404, 
    0x7467720b0f40f157, 0xa72251a87f24dbf7, 0x282a4a66ccd9f061, 0xdfac9987bda5697a, 
    0xeee50dac0ef6c9e8, 0xa7d472c153ae303e, 0x3d43f99ba5f93207, 0x61129f599a800d28, 
    0x7c1eefaadc8181df, 0xea773fd47484398f, 0xd7350a8c677c9f4b, 0x8da90d5dcc150e02, 
    0xc6256199c16300ac, 0x14ccfd4c7bfe697a, 0x52add068674d1b46, 0x05c0a26ac1319ddf, 
    0x272833359c1087ba, 0xaa8c1abe884bb3cc, 0x1d5b6c6134f87c18, 0x8a3e83a8f0a8dc57, 
    0x89c1ea88cf31e0f3,

    0xc8e91c9ad9fc0709, 0x89b65422965e2ad2, 0x607bebcba8ef6ce8, 0xf7dab275e28c46b0, 
    0x24d06c2a530f02f5, 0x98b837e4bc7bc41e, 0x7fa0af7bfd61f9fd, 0x44ecd5eb63293a38, 
    0x9c415fe744ad64be, 0xdf60c6db89d7dca1, 0xeea9340cce3a796a, 0x48865c2e1f1a98f4, 
    0x1c54de818a0c3596, 0x5d1fbd2deefc38a2, 0x375955e9361afb39, 0xa6aba951ead59e2d, 
    0xb9dd0e6405da1efc, 0x4087d51806b54348, 0xaa5afdb879773ee6, 0x670bd148cd90fd93, 
    0x0eb9e9b6c93949bc, 0xa3feda2f2e110fce, 0x8ff5268b779b3b84, 0x83ce60302b69a6dd, 
    0xc87025d2544431ee, 0xd6868b081f26f950, 0x6767727d45520335, 0xe36ae93f6102b45d, 
    0xce2040ef4d603196, 0x0c7e10571f78cb6b, 0xb15e657397b46aad, 0xc9221a16bc810b96, 
    0x4405e6cbc0884c94, 0xe701da2793327bd9, 0x4bdb6335ef12610f, 0xf744565f8e252690, 
    0x943b88e63f1c9c8a, 0x2e4a2be7fe1d22e1, 0x4e898c3afbfaaeb3, 0xa4277e8f9c3c22d0, 
    0x0eaf97e77f4e43c0, 0x89f01968660d8a56, 0xf0dde5d22ca30b2e, 0xfe4a68eed3b91278, 
    0xd0605a7224ec4e6a, 0xf7e9ba2e697d21d0, 0x448a896348d8fbd1, 0xf81b7c0b89bfba6f, 
    0x56959a67675f8f76, 0x82eb61118c738d50, 0x1e737b4c6650d72d, 0x042aa11628c9ced8, 
    0x334c6aa57ab91dd5, 0xf69411087ccc9e99, 0xad65799ac0c96137, 0xaed6f766c8973cca, 
    0xaf0ec3304c6d1fd0, 0xe0bee6ce41e6331f, 0x7a3a38932af4724e, 0x358c480890c1d3d2, 
    0x3fbdf147bcb6cfd2, 0xc1cd21b6f960be42, 0x6ba6a8688c707af0, 0xcf7776e5bc718e50, 
    0x9df27c86194c6eab, 0x5bd6202d4081505f, 0x8e893342fb3d7c93, 0xa967d44615cfab20, 
    0xe514b9c61e394257, 0xf43246ff53910ee6, 0x285eeb27b2f43968, 0x4875ee9eddb45aec, 
    0xae2a8787724680d0, 0x14b143ef2923e8fd, 0x5164003ae802b769, 0x67d82d74d719f4fd, 
    0x1b9e2f5cf2b5c1ca, 0x7be55ff292617284, 0x55d66e469f64eaf8, 0xc80bf3639944dd09, 
    0x93c44d2e0f56a1ea, 0x07fc3aac6769a04c, 0x94863d0f3be2c07e, 0x78ec0600b385e4f2, 
    0xd1be02d85796a585, 0x4cedf33fb0c6c64a, 0x9e2ca619cddf586b, 0x501c6c4dcd9a3e45, 
    0x6f5512aeb0e31bdb, 0x52ae2e33fcd78d4f, 0x8fa99827fe2301ee, 0x4c2a534a72b6a1f8, 
    0x786584ed5d146a38, 0xad0408b03b5f4be6, 0x4084710df21e1b60, 0xa759219baed39288, 
    0xae8f53ccf0a92b8b, 0x848eb55321450261, 0xd3c9c103f7e07600, 0x6d978bd91f960a27, 
    0xf3526b35e554c3a1, 0x1c025534a3dd272b, 0x3c6e19264c3503d5, 0xddaaf1781d01040c, 
    0xafa64d21fa38ab47, 0x3a375335a071a703, 0x95e90fe480a0de4a, 0x35f6f980ce9703bf, 
    0x415b571dfe5f147a, 0x7bc77159d8fcab92, 0x5dd83af9beb7d1fc, 0x0d4e65450091a8b1, 
    0xde6d1169d37cc61f, 0x0865a12d00b7a857, 0x59bec44c1b7213c5, 0x79fdb5eff763ec6f, 
    0x17a46a55ef1aec7f, 0x5866731aff4d14e0, 0xa096296c3878b4ff, 0x1767cf508bfeccae, 
    0x4f69b6cc24e38eb3, 0xa7e0bdcf7f75eb78, 0xe871727447972468, 0x0f0d84e0605d80d7, 
    0x91550ac7263dd08a, 0x2b7a734b5118da13, 0xcea3d29a19495831, 0xf96103e16cd1f971, 
    0x33b50c9e7cb73b5b, 0x5133562f99c93574, 0xc0148b3207e76080, 0x60ceaf4c2b7e21bd, 
    0x08f5e35754648cdb, 0x139a6f3fce8cfa49, 0x50ced4bf1726387d, 0x705a7932f4cc4a1b, 
    0x582c249e1c1ad8d9, 0x2251595b7cd6c8ac, 0x24c040cbf22bd074, 0x1329fce5a46295bf, 
    0xcdc2bf9bb4225518, 0xf52eac2d06e7c0b4, 0xe198ceac27474790, 0xd350539f3700a98f, 
    0x0cb0d2dfa10495bf, 0xb2253a09e371cfe2, 0xf801edbf6ee04eeb, 0x1af0c213af52d1b7, 
    0x200bf7ef41c17554, 0xb2fd7242814dfdbc, 0x8c695c069d7e12a1, 0x2b83235966b7d2cf, 
    0x7684ac2b89cccc53, 0xa33ca034e32abe0e, 0x911213e106ae9b91, 0x864f6c708e0c7450, 
    0x3d119bc13e944529, 0xa358318f1559030c, 0xa3cfa7d77e1a80a8, 0x932a0f476e115f79, 
    0xa36fa45eb155cef8, 0xf8329947f78436f3, 0x6edd2a09b67f85b2, 0x22394584a568be45, 
    0xe1c4d978a500eb76, 0x987e2d25d8c36145, 0x5b37d611a283e4b0, 0xa0af824bdf7ff34f, 
    0x51617260b0e12282, 0xfc03169e078ff53b, 0xc192c825cfe19306, 0x2bdaa113d8e1a289, 
    0xb254197d518cb97e, 0x4b63b44e7dbf57e5, 0x5f0d46ee8cb445de, 0x95345755a98d81a8, 
    0xc6190a2ed08ef423, 0xfa01768858510624, 0xe2a3c941ccccddfe, 0xeb7e6e8f737036dc, 
    0xe152d09912b68ee3, 0x05fe0cd6d1175dc5, 0x6cfe8baf2482b03a, 0x8aa8d401d963aacf, 
    0x16ebd37c25356159, 0x7dbb890c24fc3af8, 0xeeed3f8f1055c917, 0xa041fa9f11e639ec, 
    0x203b0b73bdf2b44d, 0xa70535cbd4833a2c, 0x6eb678e3d1410b02, 0x3f13c1d1920f3095, 
    0x8704d1d475c08afc, 0x721ddb50773255a4, 0xed45e9f21b4f229b, 0x019337b7e2582e3b, 
    0xbdfe88ce0c790fd7, 0xff9d887bf62bdd47, 0x25311c86466c271d, 0x78b6902839f7c52c, 
    0x6ec67300f602ae66, 0xe9ac5194801f7a47, 0x52c94142fda9bfa9, 0x5ec6b954f7d0fea0, 
    0x88d78e1921868711, 0xc649e9b5287537a1, 0xebfeeb274d528521, 0x1c3fbf943fa56125, 
    0x53cacae0efbd7a8b, 0xf3c6a27144156ab8, 0x8e173e6ac51450f0, 0x727aa23d1c6a38b6, 
    0xc7e81e3f9522b5b1, 0x06928bd2e5386483, 0x43a41398d1f84d00, 0x61d057a9ae4c602c, 
    0xaed5f36c874812ee, 0x0ce08229440a6506, 0xcebdfad21b08fea2, 0xc2eccec859c240df, 
    0xe731c05499c93442, 0xce5eeba85441924b, 0x77052dc3ee7231e9, 0x2d4f0b3942ca9fe9, 
    0xd4630d34b2f51ba2, 0xa128246178c67441, 0x27e711d8b1336f3b, 0x5a084cf73e108a02, 
    0x58a3cc1427abdabe, 0xfb2660d7b35dc35b, 0x8d8092c70533a89b, 0x39e605505aec6fbc, 
    0x59818214de37bce1, 0xe533b3ba1e323dff, 0xb2ba8a4ae140749e, 0xcbab54b97a43c427, 
    0xdec2187d033e09f6, 0x73ae8fbdddb9a54f, 0xeef0305eb998e463, 0xc39ca60eb1f54319, 
    0x7e7abe8f376cbc7e, 0x6fe15331c1e3956a, 0x4f8739ac5fab330c, 0x94e3b166d39850ee, 
    0x6be3640ab77cd2cc, 0x43e5f7a25ddf77c2, 0x0d4240a92afb9fd0, 0x2f80e6af3f5686a2, 
    0xe2299989a8ad0a12, 0x38db4c47b32a291a, 0xcb32af0a2c3814ec, 0x84a631f12a9f4d5f, 
    0x4d8ff923435f9473, 0x7363b1daf53c5282, 0xb724a24edc879d18, 0x9188ac466dfe59cb, 
    0x9360245734d82a3e, 0x9d4ae25b5af7e3e4, 0xeca2b695adfa0c90, 0xb0dcf75673d24ffd, 
    0x603b7d22de6062fc, 0x3e6b53428b4fb84a, 0x8f3e1238b4160973, 0x990271a2f1727299, 
    0x11c4c3629a27442e, 0x9bdb9fa5bc58e7b3, 0xd81e6af2cdc9b469, 0xc79c36e1bd5c08f3, 
    0x7db6a10beee8d7bc, 0x288d8c2836eead67, 0x13319b2c01dc2a1d, 0xaa146d4cd7b7dcce, 
    0x06b12af2d8aae363, 0x4792d4023a7c176a, 0x012df6b635bee421, 0xb5a26b70e6865209, 
    0xa77023d5f9ca9d9a, 0x7cb0bcad24cfe6d0, 0x2462c396d8fe13c8, 0xaf8dc14eda395e16, 
    0xf3d3cfecefe43a2c, 0x4cac2da1a3c9adaa, 0xd003de6a5216ad38, 0x5febf00304f4bf98, 
    0x18eadb270a42a78a, 0x0778554e0ab87d80, 0x8f8aa97cadc0e5fb, 0x738aa19e2a13b4e6, 
    0xd1e1e60903d377ee, 0x5ee4bcc02d48ae04, 0xca1abdb6581bc184, 0x0a628b8d2c9df8f3, 
    0x4eda706621de6733, 0x9416896ebc5f5af7, 0x071b953c83595050, 0x245810329b609e1d, 
    0x7c13c4aabdcbc521, 0x3b2c6000ccca720c, 0x0ffeb4e6b82c6635, 0xfb55f903a2f60d55, 
    0x27cf169883790ecf, 0x8c44ad0c92cf6365, 0x6e0ecc58bcd332df, 0x4fcf81c64a47e156, 
    0x3f8cc2771b7044a0, 0x81bf046a2a5afbef, 0xfd5e90034128eadb, 0xee2c30e6aa6890f6, 
    0x62a3f535f3b75be6, 0x7f63a67a3e7eca17, 0xa96bc90a0019a5f6, 0x2540afa464ecd8a7, 
    0xb2d4444f72e86369, 0x011ef141143b54a5, 0xab176b4cd2f125ee, 0x95e323207183709e, 
    0x465f6743d56bc2ec, 0xf7b08dc791752794, 0x710a594e6f4beb77, 0x043968f139338003, 
    0x515e65b836a97dc9, 0x45034c5699e786a3, 0x14e1a8d591ed143a, 0xdd90ed52064699d6, 
    0x5b014da28eade2c7, 0x87fac7982380aebf, 0xde469c10269472f6, 0x4d70d02e4e0b4549, 
    0xa227db044616a63d, 0x8d8059888fa837a2, 0x9102ffb626962622, 0x1ef23ea579af5bbf, 
    0x0382c4eaef48d6ea, 0x66cc80328497923e, 0x6011bdd5e319cb2c, 0x7eaacf296ade2760, 
    0x7a503f8a384c4476, 0x4ccc155c25118b73, 0x82f83980a7ec184c, 0x12f2672c9493cdf4, 
    0xe2b3d6308a29af91, 0xeefc4a021a20d010, 0x0bff87e12097bf8b, 0x2818b00a67e79301, 
    0x66fa2a73b35dc35c, 0x59d375f42c3fa815, 0xc1ab399cf60b949e, 0x2c60aa79196d0da3, 
    0x1599ddab8c3d2b1f, 0xa77259830e1b48af, 0xebc2fffe8b90a6e5, 0xbe663a1c78c3926c, 
    0xb9f6ddb3a50ef987, 0x65f4295b3a63c0fb, 0x8ed5e525f8072aa2, 0xe0d14b3ac7cedacd, 
    0x0e4dbb9ca5e52c81, 0x664bcbb2430a3276, 0x233d713380142297, 0x644b9a25d6f687e9, 
    0xedcc74225e5ae30e
]
