# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Shared::Caser do
  describe '.upcase' do
    it 'uppercases a Latin sample' do
      str = "I like cats. They're the best."
      expect(described_class.upcase(str)).to eq(
        "I LIKE CATS. THEY'RE THE BEST."
      )
    end

    it 'uppercases a Cyrillic sample' do
      str = 'Влади́мир Влади́мирович Пу́тин'
      expect(described_class.upcase(str)).to eq(
        'ВЛАДИ́МИР ВЛАДИ́МИРОВИЧ ПУ́ТИН'
      )
    end

    it 'uppercases a Greek sample' do
      str = 'Αλφαβητικός Κατάλογος'
      expect(described_class.upcase(str)).to eq(
        'ΑΛΦΑΒΗΤΙΚΌΣ ΚΑΤΆΛΟΓΟΣ'
      )
    end
  end

  describe '.downcase' do
    it 'lowercases a Latin sample' do
      str = "I LIKE CATS. THEY'RE THE BEST."
      expect(described_class.downcase(str)).to eq(
        "i like cats. they're the best."
      )
    end

    it 'lowercases a Cyrillic sample' do
      str = 'ВЛАДИ́МИР ВЛАДИ́МИРОВИЧ ПУ́ТИН'
      expect(described_class.downcase(str)).to eq(
        'влади́мир влади́мирович пу́тин'
      )
    end

    it 'lowercases a Greek sample' do
      str = 'ΑΛΦΑΒΗΤΙΚΌΣ ΚΑΤΆΛΟΓΟΣ'
      expect(described_class.downcase(str)).to eq(
        'αλφαβητικόσ κατάλογοσ'
      )
    end
  end

  describe '.titlecase' do
    it 'titlecases a Latin sample' do
      str = 'I LIKE CATS'
      expect(described_class.titlecase(str)).to eq(
        'I Like Cats'
      )
    end

    it 'titlecases a Cyrillic sample' do
      str = 'ВЛАДИ́МИР ВЛАДИ́МИРОВИЧ ПУ́ТИН'
      expect(described_class.titlecase(str)).to eq(
        'Влади́мир Влади́мирович Пу́тин'
      )
    end

    it 'titlecases a Greek sample' do
      str = 'ΑΛΦΑΒΗΤΙΚΌΣ ΚΑΤΆΛΟΓΟΣ'
      expect(described_class.titlecase(str)).to eq(
        'Αλφαβητικόσ Κατάλογοσ'
      )
    end

    it 'titlecases a Japanese example' do
      str = '日本語'
      expect(described_class.titlecase(str)).to eq(
        '日本語'
      )
    end
  end

  describe '.full_upcase' do
    it 'uppercases simple mappings like .upcase' do
      expect(described_class.full_upcase("I like cats. They're the best.")).to eq(
        "I LIKE CATS. THEY'RE THE BEST."
      )
    end

    it 'expands characters with multi-character full mappings' do
      expect(described_class.full_upcase('straße')).to eq('STRASSE')
      expect(described_class.full_upcase('ﬁle')).to eq('FILE')
      expect(described_class.full_upcase('ŉ')).to eq('ʼN')
      expect(described_class.full_upcase('ΐ').unpack('U*')).to eq(
        [0x0399, 0x0308, 0x0301]
      )
      expect(described_class.full_upcase('և')).to eq('ԵՒ')
    end

    it 'uppercases i to dotted İ in Turkish and Azeri' do
      expect(described_class.full_upcase('i', :tr)).to eq('İ')
      expect(described_class.full_upcase('i', :az)).to eq('İ')
      expect(described_class.full_upcase('i', :'tr-TR')).to eq('İ')
      expect(described_class.full_upcase('i')).to eq('I')
    end

    it 'removes the dot above soft-dotted characters in Lithuanian' do
      expect(described_class.full_upcase('i̇', :lt)).to eq('I')
      expect(described_class.full_upcase('j̇', :lt)).to eq('J')
    end

    it 'keeps the dot above in Lithuanian when an accent intervenes' do
      expect(described_class.full_upcase('í̇', :lt)).to eq('Í̇')
    end

    it 'does not treat characters from expanded mappings as original context' do
      # The dot above produced by lowercasing İ must not be considered
      # part of the original string when evaluating later characters.
      expect(described_class.full_downcase('İΣ').unpack('U*')).to eq(
        [0x0069, 0x0307, 0x03C2]
      )
    end
  end

  describe '.full_downcase' do
    it 'lowercases simple mappings like .downcase' do
      expect(described_class.full_downcase("I LIKE CATS. THEY'RE THE BEST.")).to eq(
        "i like cats. they're the best."
      )
    end

    it 'expands characters with multi-character full mappings' do
      expect(described_class.full_downcase('İ')).to eq('i̇')
      expect(described_class.full_downcase('ŉ')).to eq('ʼn')
      expect(described_class.full_downcase('ΐ').unpack('U*')).to eq(
        [0x03B9, 0x0308, 0x0301]
      )
    end

    it 'uses the final sigma at the end of a word' do
      expect(described_class.full_downcase('ΟΔΟΣ')).to eq('οδος')
      expect(described_class.full_downcase('ΟΣΑ')).to eq('οσα')
      expect(described_class.full_downcase('ΣΑ')).to eq('σα')
      expect(described_class.full_downcase('ΑΣ')).to eq('ας')
    end

    it 'ignores case-ignorable characters around the final sigma' do
      expect(described_class.full_downcase('ΑΣ́').unpack('U*')).to eq(
        [0x03B1, 0x03C2, 0x0301]
      )
      expect(described_class.full_downcase('ΑΣ́Β').unpack('U*')).to eq(
        [0x03B1, 0x03C3, 0x0301, 0x03B2]
      )
      expect(described_class.full_downcase("Α‍Σ").unpack('U*')).to eq(
        [0x03B1, 0x200D, 0x03C2]
      )
    end

    it 'handles Turkish and Azeri dotted and dotless I' do
      expect(described_class.full_downcase('I', :tr)).to eq('ı')
      expect(described_class.full_downcase('I', :az)).to eq('ı')
      expect(described_class.full_downcase('İ', :tr)).to eq('i')
      expect(described_class.full_downcase('İ', :tr)).to eq('i')
      expect(described_class.full_downcase('I')).to eq('i')
      expect(described_class.full_downcase('İ')).to eq('i̇')
    end

    it 'keeps the dot above in Turkish unless it follows a capital I' do
      expect(described_class.full_downcase('Ȧ', :tr)).to eq('ȧ')
      expect(described_class.full_downcase('İ̇', :tr)).to eq('i̇')
    end

    it 'adds an explicit dot above in Lithuanian when accents follow' do
      expect(described_class.full_downcase('Í', :lt)).to eq('i̇́')
      expect(described_class.full_downcase('J́', :lt)).to eq('j̇́')
      expect(described_class.full_downcase('Į́', :lt)).to eq('į̇́')
      expect(described_class.full_downcase('Ì', :lt)).to eq('i̇̀')
      expect(described_class.full_downcase('Í', :lt)).to eq('i̇́')
      expect(described_class.full_downcase('Ĩ', :lt)).to eq('i̇̃')
    end

    it 'does not add a dot above in Lithuanian without a following accent' do
      expect(described_class.full_downcase('I', :lt)).to eq('i')
      expect(described_class.full_downcase('Į', :lt)).to eq('į')
    end
  end

  describe '.full_titlecase' do
    it 'titlecases simple mappings like .titlecase' do
      expect(described_class.full_titlecase('I LIKE CATS')).to eq('I Like Cats')
    end

    it 'expands characters with multi-character full mappings' do
      expect(described_class.full_titlecase('ﬀoo bar')).to eq('Ffoo Bar')
      expect(described_class.full_titlecase('ßa')).to eq('Ssa')
    end

    it 'applies the final sigma to lowercased word tails' do
      expect(described_class.full_titlecase('ΟΔΟΣ ΤΡΟΠΟΣ')).to eq('Οδος Τροπος')
    end

    it 'honors the locale for both the head and the tail of each word' do
      expect(described_class.full_titlecase('i̇stanbul', :tr)).to eq('İ̇stanbul')
      expect(described_class.full_titlecase('İI', :tr)).to eq('İı')
    end
  end
end
