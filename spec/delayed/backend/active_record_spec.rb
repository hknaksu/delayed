require "helper"
require "delayed/backend/active_record"

describe Delayed::Backend::ActiveRecord::Job do
  it_behaves_like "a delayed_job backend"

  describe "configuration" do
    describe "reserve_sql_strategy" do
      let(:configuration) { Delayed::Backend::ActiveRecord.configuration }

      it "allows :optimized_sql" do
        configuration.reserve_sql_strategy = :optimized_sql
        expect(configuration.reserve_sql_strategy).to eq(:optimized_sql)
      end

      it "allows :default_sql" do
        configuration.reserve_sql_strategy = :default_sql
        expect(configuration.reserve_sql_strategy).to eq(:default_sql)
      end

      it "raises an argument error on invalid entry" do
        expect { configuration.reserve_sql_strategy = :invald }.to raise_error(ArgumentError)
      end
    end
  end

  describe "reserve_with_scope" do
    let(:relation_class) { Delayed::Job.limit(1).class }
    let(:worker) { instance_double(Delayed::Worker, name: "worker01", read_ahead: 1, max_claims: 1) }
    let(:scope) do
      instance_double(relation_class, update_all: nil, limit: [job]).tap do |s|
        allow(s).to receive(:where).and_return(s)
      end
    end
    let(:job) { instance_double(Delayed::Job, id: 1, assign_attributes: true, changes_applied: true) }

    before do
      allow(described_class.connection).to receive(:adapter_name).at_least(:once).and_return(dbms)
      Delayed::Backend::ActiveRecord.configuration.reserve_sql_strategy = reserve_sql_strategy
    end

    context "with reserve_sql_strategy option set to :optimized_sql (default)" do
      let(:reserve_sql_strategy) { :optimized_sql }

      context "for mysql adapters" do
        let(:dbms) { "MySQL" }

        it "uses the optimized sql version" do
          allow(described_class).to receive(:reserve_with_scope_using_default_sql)
          described_class.reserve_with_scope(scope, worker, Time.current)
          expect(described_class).not_to have_received(:reserve_with_scope_using_default_sql)
        end
      end

      context "for a dbms without a specific implementation" do
        let(:dbms) { "OtherDB" }

        it "uses the plain sql version" do
          allow(described_class).to receive(:reserve_with_scope_using_default_sql)
          described_class.reserve_with_scope(scope, worker, Time.current)
          expect(described_class).to have_received(:reserve_with_scope_using_default_sql).once
        end
      end
    end

    context "with reserve_sql_strategy option set to :default_sql" do
      let(:dbms) { "MySQL" }
      let(:reserve_sql_strategy) { :default_sql }

      it "uses the plain sql version" do
        allow(described_class).to receive(:reserve_with_scope_using_default_sql)
        described_class.reserve_with_scope(scope, worker, Time.current)
        expect(described_class).to have_received(:reserve_with_scope_using_default_sql).once
      end
    end
  end

  context "db_time_now" do
    after do
      Time.zone = nil
      ActiveRecord::Base.default_timezone = :local
    end

    it "returns time in current time zone if set" do
      Time.zone = "Arizona"
      expect(Delayed::Job.db_time_now.zone).to eq("MST")
    end

    it "returns UTC time if that is the AR default" do
      Time.zone = nil
      ActiveRecord::Base.default_timezone = :utc
      expect(described_class.db_time_now.zone).to eq "UTC"
    end

    it "returns local time if that is the AR default" do
      Time.zone = "Arizona"
      ActiveRecord::Base.default_timezone = :local
      expect(described_class.db_time_now.zone).to eq("MST")
    end
  end

  describe "after_fork" do
    it "calls reconnect on the connection" do
      allow(ActiveRecord::Base).to receive(:establish_connection)
      described_class.after_fork
      expect(ActiveRecord::Base).to have_received(:establish_connection)
    end
  end

  describe "enqueue" do
    it "allows enqueue hook to modify job at DB level" do
      later = described_class.db_time_now + 20.minutes
      job = described_class.enqueue payload_object: EnqueueJobMod.new
      expect(described_class.find(job.id).run_at).to be_within(1).of(later)
    end
  end

  if ::ActiveRecord::VERSION::MAJOR < 4 || defined?(::ActiveRecord::MassAssignmentSecurity)
    context "ActiveRecord::Base.send(:attr_accessible, nil)" do
      before do
        described_class.send(:attr_accessible, nil)
      end

      after do
        described_class.send(
          :attr_accessible,
          *described_class.new.attributes.keys,
        )
      end

      it "is still accessible" do
        job = described_class.enqueue payload_object: EnqueueJobMod.new
        expect(described_class.find(job.id).handler).not_to be_blank
      end
    end
  end

  context "ActiveRecord::Base.table_name_prefix" do
    it "when prefix is not set, use 'delayed_jobs' as table name" do
      ::ActiveRecord::Base.table_name_prefix = nil
      described_class.set_delayed_job_table_name

      expect(described_class.table_name).to eq "delayed_jobs"
    end

    it "when prefix is set, prepend it before default table name" do
      ::ActiveRecord::Base.table_name_prefix = "custom_"
      described_class.set_delayed_job_table_name

      expect(described_class.table_name).to eq "custom_delayed_jobs"

      ::ActiveRecord::Base.table_name_prefix = nil
      described_class.set_delayed_job_table_name
    end
  end
end
