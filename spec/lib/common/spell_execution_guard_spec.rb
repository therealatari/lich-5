# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../../lib/common/limitedarray'
require_relative '../../../lib/common/feature_flags'
require_relative '../../../lib/common/downstreamhook'
require_relative '../../../lib/common/upstreamhook'
require_relative '../../../lib/common/spell'

# Executes production Spell#cast and force_* methods with the production Script
# guard. dothistimeout is the deterministic command/result boundary: it checks
# the real guard before recording a simulated write. Game._puts/socket dispatch
# has separate integration coverage; this suite never opens a game connection.
RSpec.describe 'Spell execution guard cleanup and retries' do
  let(:script_class) { Lich::Common::Script }
  let(:spell_class) { Lich::Common::Spell }
  let(:owner) { script_class.allocate }
  let(:spell) { spell_class.allocate }
  let(:writes) { [] }
  let(:decision) { { value: true } }
  let(:callback) { ->(_command) { decision[:value] } }
  let(:interrupted) { Lich::Common::ScriptExecutionGuard::Interrupted }

  before(:context) do
    require_relative '../../../lib/common/script'
  end

  # Match existing Script lifecycle/pause suites' isolated native-class setup.
  after(:context) do
    %i[SubScript ExecScript WizardScript Script Scripting TRUSTED_SCRIPT_BINDING].each do |name|
      Lich::Common.send(:remove_const, name) if Lich::Common.const_defined?(name, false)
    end
    $LOADED_FEATURES.delete_if { |path| path.end_with?('/lib/common/script.rb') }
  end

  before do
    owner.want_downstream = false
    owner.want_downstream_xml = true
    allow(script_class).to receive(:__resolve_current).and_return(owner)
    allow(owner).to receive(:wait_while_paused!)
    allow(script_class).to receive(:list).and_return([owner])
    spell_class.class_variable_set(:@@cast_lock, [])
    spell_class.class_variable_set(:@@after_stance, nil)
    { num: 101, name: 'Fixture Spell', type: 'attack', circle: '1',
      no_incant: false, stance: false, channel: false, cast_proc: nil }.each do |key, value|
      spell.instance_variable_set("@#{key}", value)
    end
    stub_const('Lich::Common::Feat', Class.new)
    allow(Lich::Common::Feat).to receive(:known?).and_return(false)
    effects = Module.new
    effects.const_set(:Spells, Class.new)
    stub_const('Lich::Common::Effects', effects)
    allow(effects::Spells).to receive(:active?).and_return(false)
    %i[mana_cost spirit_cost stamina_cost].each { |method| allow(spell).to receive(method).and_return(0) }
    %i[waitrt? waitcastrt? sleep].each { |method| allow(spell).to receive(method) }
    @prepared = false
    @on_write = nil
    allow(spell).to receive(:checkprep) { @prepared ? 'Fixture Spell' : 'None' }
    allow(spell).to receive(:dothistimeout) do |command, *_args|
      owner.check_execution_guard!(command: command)
      writes << command
      if @on_write
        @on_write.call(command)
      elsif command.start_with?('prepare ')
        @prepared = true
        'Your spell is ready.'
      else
        'Cast Roundtime 3 Seconds.'
      end
    end
  end

  def expect_restored
    expect(owner.want_downstream).to be(false)
    expect(owner.want_downstream_xml).to be(true)
    expect(spell_class.class_variable_get(:@@cast_lock)).not_to include(owner)
  end

  [false, :hold].each do |denial|
    it "stops before casting when preparation changes the guard to #{denial.inspect}" do
      @on_write = lambda do |_command|
        @prepared = true
        decision[:value] = denial
        'Your spell is ready.'
      end
      expect do
        owner.with_execution_guard(callback) { spell.cast(123) }
      end.to raise_error(interrupted)
      expect(writes).to eq(['prepare 101'])
      expect_restored
    end
  end

  it 'stops a preparation timeout retry before another write and releases the cast lock' do
    @on_write = lambda do |_command|
      decision[:value] = false
      nil # Native Spell.cast retries an unanswered preparation.
    end
    expect do
      owner.with_execution_guard(callback) { spell.cast(123) }
    end.to raise_error(interrupted)
    expect(writes).to eq(['prepare 101'])
    expect_restored

    # A subsequent unguarded cast must not inherit cancellation or ownership.
    @on_write = nil
    expect(spell.cast(123)).to eq('Cast Roundtime 3 Seconds.')
    expect(writes).to eq(['prepare 101', 'prepare 101', 'cast #123'])
    expect_restored
  end

  %i[force_cast force_channel force_evoke].each do |method|
    it "guards #{method} between preparation and its forced verb" do
      @on_write = lambda do |_command|
        @prepared = true
        decision[:value] = false
        'Your spell is ready.'
      end
      expect do
        owner.with_execution_guard(callback) { spell.public_send(method, 123) }
      end.to raise_error(interrupted)
      expect(writes).to eq(['prepare 101'])
      expect_restored
    end
  end

  it 'guards force_incant when preparation-time output causes an incant retry' do
    @on_write = lambda do |_command|
      decision[:value] = false
      '[Spell preparation time: 1 second]'
    end
    expect do
      owner.with_execution_guard(callback) { spell.force_incant }
    end.to raise_error(interrupted)
    expect(writes).to eq(['incant 101'])
    expect_restored
  end

  it 'retains the native prepare/cast sequence and result without an installed guard' do
    expect(spell.cast(123)).to eq('Cast Roundtime 3 Seconds.')
    expect(writes).to eq(['prepare 101', 'cast #123'])
    expect_restored
  end

  it 'permits a normal guarded cast when every checkpoint allows execution' do
    result = owner.with_execution_guard(callback) { spell.force_channel(123) }
    expect(result).to eq('Cast Roundtime 3 Seconds.')
    expect(writes).to eq(['prepare 101', 'channel #123'])
    expect_restored
  end

  it 'keeps interruption latched when a native cast_proc rescues the guard exception' do
    spell.instance_variable_set(:@cast_proc, "dothistimeout('first', 1, /./); dothistimeout('second', 1, /./)")
    allow(spell).to receive(:echo)
    allow(spell).to receive(:respond)
    @on_write = lambda do |_command|
      decision[:value] = false
      'done'
    end
    expect do
      owner.with_execution_guard(callback) { spell.cast(123) }
    end.to raise_error(interrupted)
    expect(writes).to eq(['first'])
    expect_restored
  end
end
