pub fn is_claimed(claimed_bitmap: &Vec<u8>, index: u32) -> bool {
    let byte_index = (index / 8) as usize; // Index of the byte in the array
    if byte_index >= claimed_bitmap.len() {
        return false; // Out of bounds, treat as not claimed
    }
    let bit_in_byte_index = (index % 8) as usize; // Index of the bit within the byte
    let claimed_byte = claimed_bitmap[byte_index];
    let mask = 1 << bit_in_byte_index;
    claimed_byte & mask == mask
}

pub fn set_claimed(claimed_bitmap: &mut Vec<u8>, index: u32) {
    let byte_index = (index / 8) as usize; // Index of the byte in the array
    if byte_index >= claimed_bitmap.len() {
        let new_size = byte_index + 1;
        claimed_bitmap.resize(new_size, 0); // Resize the Vec if necessary
    }
    let bit_in_byte_index = (index % 8) as usize; // Index of the bit within the byte
    claimed_bitmap[byte_index] |= 1 << bit_in_byte_index;
}
