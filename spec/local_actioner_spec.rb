require 'spec_helper'

describe DynamoAutoscale::Actioner do
  let(:table)    { DynamoAutoscale::TableTracker.new("table") }
  let(:actioner) { DynamoAutoscale::LocalActioner.new(table) }

  before { DynamoAutoscale.current_table = table }
  after  { DynamoAutoscale.current_table = nil }
  after  { Timecop.return }

  describe "scaling down" do
    before do
      table.tick(5.minutes.ago, {
        provisioned_writes: 100, consumed_writes: 50,
        provisioned_reads:  100, consumed_reads:  20,
      })
    end

    it "should not be allowed more than 4 times per day" do
      actioner.set(:writes, 90).should be_true
      actioner.set(:writes, 80).should be_true
      actioner.set(:writes, 70).should be_true
      actioner.set(:writes, 60).should be_true
      actioner.set(:writes, 60).should be_false
    end

    it "is not per metric, it is per table" do
      actioner.set(:reads,  90).should be_true
      actioner.set(:writes, 80).should be_true
      actioner.set(:reads,  70).should be_true
      actioner.set(:writes, 60).should be_true
      actioner.set(:writes, 60).should be_false
    end
  end

  describe "scale resets" do
    before do
      table.tick(5.minutes.ago, {
        provisioned_writes: 100, consumed_writes: 50,
        provisioned_reads:  100, consumed_reads:  20,
      })
    end

    it "once per day at midnight" do
      actioner.set(:writes, 90)
      actioner.set(:writes, 80)
      actioner.set(:writes, 70)
      actioner.set(:writes, 60)
      actioner.set(:writes, 50)

      actioner.provisioned_writes.length.should == 4
      actioner.downscales.should == 4
      actioner.upscales.should == 0
      time, value = actioner.provisioned_for(:writes).last
      value.should == 60

      Timecop.travel(1.day.from_now.utc.midnight)

      actioner.set(:writes, 50)
      actioner.set(:writes, 40)
      actioner.set(:writes, 30)
      actioner.set(:writes, 20)
      actioner.set(:writes, 10)

      actioner.provisioned_writes.length.should == 8
      actioner.downscales.should == 4
      actioner.upscales.should == 0
      time, value = actioner.provisioned_for(:writes).last
      value.should == 20
    end

    specify "and not a second sooner" do
      actioner.set(:writes, 90).should be_true
      actioner.set(:writes, 80).should be_true
      actioner.set(:writes, 70).should be_true
      actioner.set(:writes, 60).should be_true
      actioner.set(:writes, 60).should be_false
      actioner.downscales.should == 4
      actioner.upscales.should == 0

      Timecop.travel(1.day.from_now.utc.midnight - 1.second)

      actioner.set(:writes, 50).should be_false
      actioner.downscales.should == 4
      actioner.upscales.should == 0
    end
  end

  describe "scaling up" do
    before do
      table.tick(5.minutes.ago, {
        provisioned_writes: 100, consumed_writes: 50,
        provisioned_reads:  100, consumed_reads:  20,
      })

      actioner.set(:writes, 100000).should be_true
    end

    it "should only go up to 2x your current provisioned" do
      time, val = actioner.provisioned_writes.last
      val.should == 200
    end

    it "can happen as much as it fucking wants to" do
      100.times do
        actioner.set(:writes, 100000).should be_true
      end
    end
  end

  describe "grouping actions" do
    let(:actioner) { DynamoAutoscale::LocalActioner.new(table, group_downscales: true) }

    before do
      table.tick(5.minutes.ago, {
        provisioned_writes: 100, consumed_writes: 50,
        provisioned_reads:  100, consumed_reads:  20,
      })
    end

    describe "writes" do
      before do
        actioner.set(:writes, 10)
      end

      it "should not apply a write without an accompanying read" do
        actioner.provisioned_for(:writes).last.should be_nil
      end
    end

    describe "reads" do
      before do
        actioner.set(:reads, 10)
      end

      it "should not apply a read without an accompanying write" do
        actioner.provisioned_for(:reads).last.should be_nil
      end
    end

    describe "a write and a read" do
      before do
        actioner.set(:reads, 10)
        actioner.set(:writes, 10)
      end

      it "should be applied" do
        time, value = actioner.provisioned_for(:reads).last
        value.should == 10

        time, value = actioner.provisioned_for(:writes).last
        value.should == 10
      end
    end

    describe "flushing after a period of time" do
      let(:actioner) do
        DynamoAutoscale::LocalActioner.new(table, {
          group_downscales: true,
          flush_after: 5.minutes,
        })
      end

      describe "happy path" do
        before do
          actioner.set(:reads, 10)
          actioner.set(:reads, 5)

          Timecop.travel(10.minutes.from_now)
          actioner.try_flush!
        end

        it "should flush" do
          actioner.provisioned_reads.length.should == 1
          time, value = actioner.provisioned_reads.last
          value.should == 5
        end
      end

      describe "unhappy path" do
        before do
          actioner.set(:reads, 10)
          actioner.set(:reads, 5)
          actioner.try_flush!
        end

        it "should not flush" do
          actioner.provisioned_reads.length.should == 0
          time, value = actioner.provisioned_reads.last
          value.should be_nil
        end
      end
    end
  end
end
