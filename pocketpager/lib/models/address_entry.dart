class AddressEntry {
  final int address;
  String name;
  String notes;

  AddressEntry({required this.address, required this.name, this.notes = ''});

  Map<String, dynamic> toJson() => {
        'address': address,
        'name': name,
        'notes': notes,
      };

  factory AddressEntry.fromJson(Map<String, dynamic> j) => AddressEntry(
        address: j['address'] as int,
        name: j['name'] as String,
        notes: (j['notes'] as String?) ?? '',
      );
}
