require 'spec_helper'

describe '.client' do
  let(:client) { instance_double(Aws::DynamoDB::Client) }

  it 'should create the client only once' do
    expect(Aws::DynamoDB::Client).to receive(:new).with(
                                         region: Dynamini.configuration.region,
                                         access_key_id: Dynamini.configuration.access_key_id,
                                         secret_access_key: Dynamini.configuration.secret_access_key).once.and_return(client)
    Dynamini::Base.client
    Dynamini::Base.client
  end
end

describe Dynamini::Base do
  let(:client) { instance_double(Aws::DynamoDB::Client) }
  let(:model_attributes) { {name: 'Widget', price: 9.99, id: 'abcd1234'} }

  subject(:model) { Dynamini::Base.new(model_attributes).tap { |model| model.send(:clear_changes) } }

  before do
    allow(Dynamini::Base).to receive(:client).and_return(client)
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

    describe '.new' do
      let(:dirty_model) { Dynamini::Base.new(model_attributes) }

      it 'should append all initial attributes to @changed, including hash_key' do
        expect(dirty_model.changed).to eq(model_attributes.keys.map(&:to_s))
      end

      it 'should not include the primary key in the changes' do
        expect(dirty_model.changes[:id]).to be_nil
      end
    end

    describe '.create' do
      it 'should call put_item' do
        expect(client).to receive(:update_item).with(table_name: 'bases',
                                                     key: {id: model_attributes[:id]},
                                                     attribute_updates: hash_including({name: {value: 'Widget', action: 'PUT'}, price: {value: 9.99, action: 'PUT'}}))
        Dynamini::Base.create(model_attributes)
      end

      it 'should return an instance of the model' do
        allow(client).to receive(:update_item)
        expect(Dynamini::Base.create(model_attributes).attributes).to eq(model_attributes)
      end

      context 'when creating a subclass' do
        class Foo < Dynamini::Base
        end

        it 'should return the object as an instance of the subclass' do
          allow(client).to receive(:update_item)
          expect(Foo.create(value: '1')).to be_a Foo
        end
      end
    end

    describe '.find' do
      let(:response) { double(:get_response, item: model_attributes.stringify_keys) }

      it 'should call get_item' do
        expect(client).to receive(:get_item).with(table_name: 'bases', key: {id: model_attributes[:id]}).and_return response
        Dynamini::Base.find('abcd1234')
      end

      it 'should return a model with the retrieved attributes' do
        allow(client).to receive(:get_item).and_return(response)
        expect(Dynamini::Base.find('abcd1234').attributes).to eq(model_attributes)
      end

      context 'when the object does not exist' do
        let(:response) { double(:empty_response, item: nil) }

        it 'should raise an error' do
          allow(client).to receive(:get_item).and_return(response)
          expect { Dynamini::Base.find('foo') }.to raise_error 'Item not found.'
        end

      end

      context 'when retrieving a subclass' do
        class Foo < Dynamini::Base
        end

        it 'should return the object as an instance of the subclass' do
          allow(client).to receive(:get_item).and_return(response)
          expect(Foo.find('1')).to be_a Foo
        end
      end
    end

    describe '.enqueue_for_save' do
      before do
        Dynamini::Base.batch_write_queue = []
      end
      context 'when enqueuing a valid object' do
        it 'should return true' do
          expect(Dynamini::Base.enqueue_for_save(model_attributes)).to eq true
        end
        it 'should append the object to the batch_write_queue' do
          Dynamini::Base.enqueue_for_save(model_attributes)
          expect(Dynamini::Base.batch_write_queue.length).to eq 1
        end
      end

      context 'when enqueuing an invalid object' do
        let(:bad_attributes) { {name: 'bad', id: nil} }
        before do
          allow_any_instance_of(Dynamini::Base).to receive(:valid?).and_return(false)
        end
        it 'should return false' do
          expect(Dynamini::Base.enqueue_for_save(bad_attributes)).to eq false
        end
        it 'should not append the object to the queue' do
          Dynamini::Base.enqueue_for_save(bad_attributes)
          expect(Dynamini::Base.batch_write_queue.length).to eq 0
        end
      end

      context 'when reaching the batch size threshold' do
        before do
          stub_const('Dynamini::Base::BATCH_SIZE', 1)
          allow(Dynamini::Base).to receive(:dynamo_batch_save)
        end
        it 'should return true' do
          expect(Dynamini::Base.enqueue_for_save(model_attributes)).to eq true
        end
        it 'should flush the queue' do
          Dynamini::Base.enqueue_for_save(model_attributes)
          expect(Dynamini::Base.batch_write_queue).to be_empty
        end
      end
    end

    describe '.flush_queue!' do
      it 'should empty the queue' do
        allow(Dynamini::Base).to receive(:dynamo_batch_save)
        Dynamini::Base.enqueue_for_save(model_attributes)
        Dynamini::Base.flush_queue!
        expect(Dynamini::Base.batch_write_queue).to be_empty
      end
      it 'should return the response from the db operation' do
        expect(Dynamini::Base).to receive(:dynamo_batch_save).and_return('foo')
        expect(Dynamini::Base.flush_queue!).to eq 'foo'
      end
      it 'should send the contents of the queue to dynamo_batch_save' do
        Dynamini::Base.enqueue_for_save(model_attributes)
        expect(Dynamini::Base).to receive(:dynamo_batch_save).with(Dynamini::Base.batch_write_queue)
        Dynamini::Base.flush_queue!
      end
    end

    describe '.dynamo_batch_save' do
      it 'should batch write the models to dynamo' do
        model2 = Dynamini::Base.new(id: 123)

        expect(client).to receive(:batch_write_item).with({request_items: {
                                                              'bases' => [
                                                                  {put_request: {item: hash_including(model_attributes.stringify_keys)}},
                                                                  {put_request: {item: hash_including(model2.attributes.stringify_keys)}}
                                                              ]
                                                          }})
        Dynamini::Base.dynamo_batch_save([model, model2])
      end
    end

    describe '.batch_find' do
      context 'when requesting 0 items' do
        it 'should return an empty array' do
          expect(Dynamini::Base.batch_find).to eq []
        end
      end
      context 'when requesting 2 items' do
        it 'should return a 2-length array containing each item' do
          model2 = Dynamini::Base.new(id: 4321)
          response = OpenStruct.new(responses: {'bases' => [model, model2]})
          expect(client).to receive(:batch_get_item).and_return response
          items = Dynamini::Base.batch_find(['foo', 'bar'])
          expect(items.length).to eq 2
          expect(items.first.id).to eq model.id
          expect(items.last.id).to eq 4321
        end
      end
      context 'when requesting too many items' do
        it 'should raise an error' do
          array = []
          150.times { array << 'foo' }
          expect { Dynamini::Base.batch_find(array) }.to raise_error StandardError
        end
      end
    end

    describe '.find_or_new' do
      let(:response) { double(:get_response, item: model_attributes.stringify_keys) }
      let(:empty_response) { Dynamini::Base.new() }
      context 'when a record with the given key exists' do
        it 'should return that record' do
          allow(client).to receive(:get_item).and_return(response)
          expect(Dynamini::Base.find_or_new('abcd1234').new_record?).to be_falsey
        end
      end
      context 'when the key cannot be found' do
        it 'should initialize a new object with that key' do
          allow(client).to receive(:get_item).and_return(empty_response)
          expect(Dynamini::Base.find_or_new('foo').new_record?).to be_truthy
        end
      end
    end


    describe '#assign_attributes' do
      it 'should return nil' do
        expect(model.assign_attributes(price: 5)).to be_nil
      end

      it 'should update the attributes of the model' do
        allow(client).to receive(:update_item)
        model.assign_attributes(price: 5)
        expect(model.attributes[:price]).to eq(5)
      end

      it 'should append changed attributes to @changed' do
        model.assign_attributes(name: 'Widget', price: 5)
        expect(model.changed).to eq ['price']
      end
    end

    describe '#save' do
      before do
        allow(client).to receive(:update_item)
      end

      context 'when passing validation' do
        it 'should return true' do
          expect(model.save).to eq true
        end

        context 'something has changed' do
          it 'should call update_item with the changed attributes' do
            expect(client).to receive(:update_item).with(table_name: 'bases',
                                                         key: {id: model_attributes[:id]},
                                                         attribute_updates: hash_including({price: {value: 5, action: 'PUT'}}))
            model.price = 5
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
            expect(client).to receive(:update_item).with(table_name: 'bases',
                                                         key: {id: model_attributes[:id]},
                                                         attribute_updates: hash_not_including({foo: {value: '', action: 'PUT'}}))
            model.foo = ''
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
          expect(client).not_to receive(:update_item)
          model.save
        end
      end

      context 'nothing has changed' do
        it 'should not trigger an update' do
          expect(client).not_to receive(:update_item)
          model.save
        end
      end

      context 'when validation is ignored' do
        it 'should trigger an update' do
          allow(client).to receive(:update_item)
          allow(model).to receive(:valid?).and_return(false)
          model.price = 5
          expect(model.save!(validate: false)).to eq true
        end
      end

    end
  end

  describe '#touch' do
    it 'should only send the updated time timestamp to the client' do
      allow(Time).to receive(:now).and_return 1
      expect(client).to receive(:update_item).with(table_name: 'bases',
                                                   key: {id: model_attributes[:id]},
                                                   attribute_updates: {updated_at: {value: 1.0, action: 'PUT'}})
      expect { model.touch }.to raise_error RuntimeError
      model.instance_variable_set(:@new_record, false)
      model.touch
    end
  end

  describe '#save!' do
    class TestValidation < Dynamini::Base
      self.hash_key = :bar
      validates_presence_of :foo
    end

    it 'should raise its failed validation errors' do
      model = TestValidation.new(bar: 'baz')
      expect { model.save! }.to raise_error StandardError
    end

    it 'should not validate if validate: false is passed' do
      allow(client).to receive(:update_item)
      model = TestValidation.new(bar: 'baz')
      expect(model.save!(validate: false)).to eq true
    end
  end

  describe '.create!' do
    class TestValidation < Dynamini::Base
      self.hash_key = :bar
      validates_presence_of :foo
    end

    it 'should raise its failed validation errors' do
      expect { TestValidation.create!(bar: 'baz') }.to raise_error StandardError
    end
  end

  describe '#trigger_save' do
    let(:time) { Time.now }
    before do
      allow(Time).to receive(:now).and_return(time)
    end
    context 'new record' do
      it 'should set created and updated time to current time' do
        expect(client).to receive(:update_item).with(table_name: 'bases',
                                                     key: {id: model_attributes[:id]},
                                                     attribute_updates: {price: {value: 5, action: 'PUT'},
                                                                         created_at: {value: time.to_f, action: 'PUT'},
                                                                         updated_at: {value: time.to_f, action: 'PUT'}})
        model.price = 5
        model.save
      end
    end
    context 'existing record' do
      it 'should set updated time but not created time' do
        expect(client).to receive(:update_item).with(table_name: 'bases',
                                                     key: {id: model_attributes[:id]},
                                                     attribute_updates: {price: {value: 5, action: 'PUT'},
                                                                         updated_at: {value: time.to_f, action: 'PUT'}})
        model.instance_variable_set(:@new_record, false)
        model.price = 5
        model.save
      end
    end
    context 'when suppressing timestamps' do
      it 'should not set either timestamp' do
        expect(client).to receive(:update_item).with(table_name: 'bases',
                                                     key: {id: model_attributes[:id]},
                                                     attribute_updates: {price: {value: 5, action: 'PUT'}})
        model.instance_variable_set(:@new_record, false)
        model.price = 5
        model.save(skip_timestamps: true)
      end
    end


  end

  describe 'metaconfig' do
    class TestModel < Dynamini::Base
      self.hash_key = :email
      self.table_name = 'people'
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
        expect(model.attributes).to eq model_attributes
      end

    end


    describe '#new_record?' do

      let(:response) { double(:get_response, item: model_attributes.stringify_keys) }
      it 'should return true for a new record' do
        expect(model.new_record?).to be_truthy
      end
      it 'should return false for a retrieved record' do
        allow(client).to receive(:get_item).and_return(response)
        expect(Dynamini::Base.find('abcd1234').new_record?).to be_falsey
      end
      it 'should return false after a new record is saved' do
        allow(client).to receive(:update_item).and_return(response)
        model.foo = 'bar'
        model.save
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

      context 'attempting to write to hash_key' do
        it 'should raise an error' do
          expect { model.id = 1 }.to raise_error StandardError
        end
      end

      context 'existing attribute' do
        before { model.price = 1 }
        it 'should overwrite the attribute' do
          expect(model.price).to eq(1)
        end
      end
      context 'new attribute' do
        before { model.foo = 'bar' }
        it 'should write to the attribute' do
          expect(model.foo).to eq('bar')
        end
      end
    end

    describe '#changed' do
      context 'no change detected' do
        before { model.price = 9.99 }
        it 'should return an empty array' do
          expect(model.changed).to be_empty
        end
      end

      context 'attribute changed' do
        before { model.price = 1 }
        it 'should include the changed attribute' do
          expect(model.changed).to include('price')
        end
      end

      context 'attribute created' do
        before { model.foo = 'bar' }
        it 'should include the created attribute' do
          expect(model.changed).to include('foo')
        end
      end

      context 'attribute changed twice' do
        before do
          model.foo = 'bar'
          model.foo = 'baz'
        end
        it 'should only include one copy of the changed attribute' do
          expect(model.changed).to eq(['foo'])
        end
      end
    end
  end
end

