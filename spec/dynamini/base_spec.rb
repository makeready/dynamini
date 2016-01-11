require 'spec_helper'

describe Dynamini::Base do
  let(:model_attributes) {
    {
        name: 'Widget',
        price: 9.99,
        id: 'abcd1234',
        hash_key: '009'
    }
  }

  subject(:model) { Dynamini::Base.new(model_attributes) }

  class TestClassWithRange < Dynamini::Base
    set_hash_key :foo
    set_range_key :bar
    self.in_memory = true
    handle :bar, :integer
  end

  before do
    model.save
  end

  describe '.set_table_name' do
    before do
      class TestClass < Dynamini::Base
      end
    end
    it 'should' do
      expect(TestClass.table_name).to eq('test_classes')
    end
  end

  describe '#configure' do
    before do
      Dynamini.configure do |config|
        config.region = 'eu-west-1'
      end
    end

    it 'returns the configured variables' do
      expect(Dynamini.configuration.region).to eq('eu-west-1')
    end
  end


  describe 'operations' do

    describe '.create' do
      it 'should save the item' do
        other_model_attributes = model_attributes
        other_model_attributes[:id] = 'xyzzy'
        Dynamini::Base.create(other_model_attributes)
        expect(Dynamini::Base.find(other_model_attributes[:id])).to_not be_nil
      end

      it 'should return an instance of the model' do
        expect(Dynamini::Base.create(model_attributes)).to be_a(Dynamini::Base)
      end

      context 'when creating a subclass' do
        class Foo < Dynamini::Base
        end

        it 'should return the object as an instance of the subclass' do
          expect(Foo.create(value: '1')).to be_a Foo
        end
      end
    end

    describe '#==' do
      let(:model_a) { Dynamini::Base.new(model_attributes).tap {
          |model| model.send(:clear_changes)
      } }
      let(:model_attributes_d) { {
          name: 'Widget',
          price: 9.99,
          hash_key: '007'
      } }

      context 'when the object is reflexive ( a = a )' do
        it 'it should return true' do
          expect(model_a.==(model_a)).to be_truthy
        end
      end

      context 'when the object is symmetric ( if a = b then b = a )' do
        it 'it should return true' do
          model_b = model_a
          expect(model_a.==(model_b)).to be_truthy
        end
      end

      context 'when the object is transitive (if a = b and b = c then a = c)' do
        it 'it should return true' do
          model_b = model_a
          model_c = model_b
          expect(model_a.==(model_c)).to be_truthy
        end
      end

      context 'when the object attributes are different' do
        it 'should return false' do
          model_d = Dynamini::Base.new(model_attributes_d).tap {
              |model| model.send(:clear_changes)
          }
          expect(model_a.==(model_d)).to be_falsey
        end
      end
    end

    describe '#assign_attributes' do
      it 'should return nil' do
        expect(model.assign_attributes(price: '5')).to be_nil
      end

      it 'should update the attributes of the model' do
        model.assign_attributes(price: '5')
        expect(model.attributes[:price]).to eq('5')
      end

      it 'should append changed attributes to @changed' do
        model.assign_attributes(name: 'Widget', price: '5')
        expect(model.changed).to eq ['price']
      end
    end

    describe '#update_attribute' do

      it 'should update the attribute and save the object' do
        expect(model).to receive(:save!)
        model.update_attribute(:name, 'Widget 2.0')
        expect(model.name).to eq('Widget 2.0')
      end
    end

    describe '#update_attributes' do
      it 'should update multiple attributes and save the object' do
        expect(model).to receive(:save!)
        model.update_attributes(name: 'Widget 2.0', price: '12.00')
        expect(model.attributes).to include(name: 'Widget 2.0', price: '12.00')
      end
    end

    describe '#save' do

      context 'when passing validation' do
        it 'should return true' do
          expect(model.save).to eq true
        end

        context 'something has changed' do
          it 'should call update_item with the changed attributes' do
            expect(model.class.client).to receive(:update_item).with(
                                              table_name: 'bases',
                                              key: {id: model_attributes[:id]},
                                              attribute_updates: hash_including(
                                                  "price" => {
                                                      value: '5',
                                                      action: 'PUT'
                                                  }
                                              )
                                          )
            model.price = '5'
            model.save
          end

          it 'should not return any changes after saving' do
            model.price = 5
            model.save
            expect(model.changed).to be_empty
          end
        end

        context 'when a blank field has been added' do
          it 'should suppress any blank keys' do
            expect(model.class.client).to receive(:update_item).with(
                                              table_name: 'bases',
                                              key: {id: model_attributes[:id]},
                                              attribute_updates: hash_not_including(
                                                  foo: {
                                                      value: '',
                                                      action: 'PUT'
                                                  }
                                              )
                                          )
            model.foo = ''
            model.bar = 4
            model.save
          end
        end
      end

      context 'when failing validation' do
        before do
          allow(model).to receive(:valid?).and_return(false)
          model.price = 5
        end

        it 'should return false' do
          expect(model.save).to eq false
        end

        it 'should not trigger an update' do
          expect(model.class.client).not_to receive(:update_item)
          model.save
        end
      end

      context 'nothing has changed' do
        it 'should not trigger an update' do
          expect(model.class.client).not_to receive(:update_item)
          model.save
        end
      end

      context 'when validation is ignored' do
        it 'should trigger an update' do
          allow(model).to receive(:valid?).and_return(false)
          model.price = 5
          expect(model.save!(validate: false)).to eq true
        end
      end
    end

    describe '#delete' do
      context 'when the item exists in the DB' do
        it 'should delete the item and return the item' do
          expect(model.delete).to eq(model)
          expect { Dynamini::Base.find(model.id) }.to raise_error ('Item not found.')
        end
      end
      context 'when the item does not exist in the DB' do
        it 'should return the item' do
          expect(model.delete).to eq(model)
        end
      end
    end
  end

  describe '#touch' do
    it 'should only send the updated time timestamp to the client' do
      allow(Time).to receive(:now).and_return 1
      expect(model.class.client).to receive(:update_item).with(
                                        table_name: 'bases',
                                        key: {id: model_attributes[:id]},
                                        attribute_updates: {
                                            updated_at: {
                                                value: 1,
                                                action: 'PUT'
                                            }
                                        }
                                    )
      model.touch
    end

    it 'should raise an error when called on a new record' do
      new_model = Dynamini::Base.new(id: '3456')
      expect { new_model.touch }.to raise_error StandardError
    end
  end

  describe '#save!' do

    context 'hash key only' do
      class TestValidation < Dynamini::Base
        set_hash_key :bar
        validates_presence_of :foo
        self.in_memory = true
      end

      it 'should raise its failed validation errors' do
        model = TestValidation.new(bar: 'baz')
        expect { model.save! }.to raise_error StandardError
      end

      it 'should not validate if validate: false is passed' do
        model = TestValidation.new(bar: 'baz')
        expect(model.save!(validate: false)).to eq true
      end
    end
  end

  describe '.create!' do
    class TestValidation < Dynamini::Base
      set_hash_key :bar
      validates_presence_of :foo
    end

    it 'should raise its failed validation errors' do
      expect { TestValidation.create!(bar: 'baz') }.to raise_error StandardError
    end
  end

  describe '#trigger_save' do
    class TestHashRangeTable < Dynamini::Base
      set_hash_key :bar
      set_range_key :abc
    end

    TestHashRangeTable.in_memory = true

    let(:time) { Time.now }
    before do
      allow(Time).to receive(:now).and_return(time)
    end
    context 'new record' do
      it 'should set created and updated time to current time for hash key only table' do
        new_model = Dynamini::Base.create(id: '6789')
        # stringify to handle floating point rounding issue
        expect(new_model.created_at.to_s).to eq(time.to_s)
        expect(new_model.updated_at.to_s).to eq(time.to_s)
        expect(new_model.id).to eq('6789')
      end

      # create fake dynamini child class for testing range key

      it 'should set created and updated time to current time for hash and range key table' do
        new_model = TestHashRangeTable.create!(bar: '6789', abc: '1234')

        # stringify to handle floating point rounding issue
        expect(new_model.created_at.to_s).to eq(time.to_s)
        expect(new_model.updated_at.to_s).to eq(time.to_s)
        expect(new_model.bar).to eq('6789')
        expect(new_model.abc).to eq('1234')
      end

    end
    context 'existing record' do
      it 'should set updated time but not created time' do
        existing_model = Dynamini::Base.new({name: 'foo'}, false)
        existing_model.price = 5
        existing_model.save
        expect(existing_model.updated_at.to_s).to eq(time.to_s)
        expect(existing_model.created_at.to_s).to_not eq(time.to_s)
      end
      it 'should not update created_at again' do
        object = Dynamini::Base.new(name: 'foo')
        object.save
        created_at = object.created_at
        object.name = "bar"
        object.save
        expect(object.created_at).to eq created_at
      end
      it 'should preserve previously saved attributes' do
        model.foo = '1'
        model.save
        model.bar = 2
        model.save
        expect(model.foo).to eq '1'
      end
    end
    context 'when suppressing timestamps' do
      it 'should not set either timestamp' do
        existing_model = Dynamini::Base.new({name: 'foo'}, false)
        existing_model.price = 5

        existing_model.save(skip_timestamps: true)

        expect(existing_model.updated_at.to_s).to_not eq(time.to_s)
        expect(existing_model.created_at.to_s).to_not eq(time.to_s)
      end
    end
  end

  describe 'table config' do
    class TestModel < Dynamini::Base
      set_hash_key :email
      set_table_name 'people'

    end

    it 'should override the primary_key' do
      expect(TestModel.hash_key).to eq :email
    end

    it 'should override the table_name' do
      expect(TestModel.table_name).to eq 'people'
    end
  end


  describe 'attributes' do
    describe '#attributes' do
      it 'should return all attributes of the object' do
        expect(model.attributes).to include model_attributes
      end
    end

    describe '#new_record?' do
      it 'should return true for a new record' do
        expect(Dynamini::Base.new).to be_truthy
      end
      it 'should return false for a retrieved record' do
        expect(Dynamini::Base.find('abcd1234').new_record?).to be_falsey
      end
      it 'should return false after a new record is saved' do
        expect(model.new_record?).to be_falsey
      end
    end

    describe 'reader method' do
      it { is_expected.to respond_to(:price) }
      it { is_expected.not_to respond_to(:foo) }

      context 'existing attribute' do
        it 'should return the attribute' do
          expect(model.price).to eq(9.99)
        end
      end

      context 'new attribute' do
        before { model.description = 'test model' }
        it 'should return the attribute' do
          expect(model.description).to eq('test model')
        end
      end

      context 'nonexistent attribute' do
        it 'should return nil' do
          expect(subject.foo).to be_nil
        end
      end

      context 'attribute set to nil' do
        before { model.price = nil }
        it 'should return nil' do
          expect(model.price).to be_nil
        end
      end
    end

    describe 'writer method' do
      it { is_expected.to respond_to(:baz=) }

      context 'existing attribute' do
        before { model.price = '1' }
        it 'should overwrite the attribute' do
          expect(model.price).to eq('1')
        end
      end
      context 'new attribute' do
        before { model.foo = 'bar' }
        it 'should write to the attribute' do
          expect(model.foo).to eq('bar')
        end
      end
    end

    describe '#key' do
      context 'when using hash key only' do

        before do
          class TestClass < Dynamini::Base
            set_hash_key :foo
            self.in_memory = true
          end
        end

        it 'should return an hash containing only the hash_key name and value' do
          expect(TestClass.new(foo: 2).send(:key)).to eq(foo: 2)
        end
      end
      context 'when using both hash_key and range_key' do
        it 'should return an hash containing only the hash_key name and value' do
          key_hash = TestClassWithRange.new(foo: 2, bar: 2015).send(:key)
          expect(key_hash).to eq(foo: 2, bar: 2015)
        end
      end
    end
  end
end

