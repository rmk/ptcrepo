delivery/                                                                                           0000775 0001750 0001750 00000000000 11660431220 013020  5                                                                                                    ustar   adegtiar                        adegtiar                                                                                                                                                                                                               delivery/multicast.rb                                                                               0000664 0001750 0001750 00000004662 11660431220 015362  0                                                                                                    ustar   adegtiar                        adegtiar                                                                                                                                                                                                               require 'delivery/reliable'
require 'voting/voting'
require 'membership/membership.rb'

# @abstract MulticastProtocol is the abstract interface for multicast message delivery.
# A multicast implementation should subclass MulticastProtocol and mix in a
# chosen DeliveryProtocol and MembershipProtocol.
module MulticastProtocol
  state do
    # Used to request that a new message be delivered to all members in the
    # Membership module.
    # @param [Number] ident a unique id for the message
    # @param [Object] payload the message payload
    interface input, :mcast_send, [:ident] => [:payload]

    # Used to indicate that a new message has been delivered to all members.
    # @param [Number] ident the unique id of the delivered message
    interface output, :mcast_done, [:ident]
  end
end

# @abstract Multicast is an abstract implementation for multicast message delivery. The functionality is implemented, but it depends on an implemented DeliveryProtocol and MembershipProtocol to be mixed in.
# A simple implementation of Multicast, which depends on abstract delivery
# and membership modules.
module Multicast
  include MulticastProtocol
  include DeliveryProtocol
  include MembershipProtocol

  state do
    # Keeps track of the number of messages that need to be confirmed
    # as sent for a given mcast id.
    table :unacked_count, [:ident] => [:num]
    # A scratch noting the number of members in this tick.
    scratch :num_members, [] => [:num]
    # A scratch of the number of messages confirmed this timestep for
    # a given mcast id.
    scratch :acked_count, [:ident] => [:num]
  end
  
  bloom :snd_mcast do 
    pipe_in <= (mcast_send * member).pairs do |s, m|
      [m.host, ip_port, s.ident, s.payload] unless m.host == ip_port
    end
  end

  bloom :init_unacked do
    num_members <= member.group(nil, count)
    unacked_count <= (mcast_send * num_members).pairs do |s, c|
      [s.ident, c.num]
    end
  end

  bloom :done_mcast do
    acked_count <= pipe_sent.group([:ident], count(:ident))
    unacked_count <+- (acked_count * unacked_count).pairs do |a, u|
      [a.ident, u.num - a.num]
    end
    mcast_done <= unacked_count {|u| [u.ident] if u.num == 0}
    unacked_count <- unacked_count {|u| u if u.num == 0}
  end
end

module BestEffortMulticast
  include BestEffortDelivery
  include Multicast
  include StaticMembership
end

module ReliableMulticast
  include ReliableDelivery
  include Multicast
  include StaticMembership
end
                                                                              test/                                                                                               0000775 0001750 0001750 00000000000 11660431232 012157  5                                                                                                    ustar   adegtiar                        adegtiar                                                                                                                                                                                                               test/tc_multicast.rb                                                                                0000664 0001750 0001750 00000006140 11660431343 015203  0                                                                                                    ustar   adegtiar                        adegtiar                                                                                                                                                                                                               require 'rubygems'
require 'bud'
require 'test/unit'
require 'delivery/multicast'

module TestState
  include StaticMembership

  state do
    table :mcast_done_perm, [:ident]
    table :rcv_perm, [:ident] => [:payload]
  end

  bloom :mem do
    mcast_done_perm <= mcast_done
    rcv_perm <= pipe_out {|r| [r.ident, r.payload]}
  end
end

class MC
  include Bud
  include TestState
  include BestEffortMulticast
end

class RMC
  include Bud
  include TestState
  include ReliableMulticast
end

# Unreliable multicast: doesn't reply with acks.
class URMC
  include Bud
  include TestState
  include ReliableMulticast

  bloom :rcv do
    pipe_out <= bed.pipe_out
    #Don't ack.
  end
end


class TestMC < Test::Unit::TestCase

  def init_members(test_class)
    mc = test_class.new
    mc2 = test_class.new
    mc3 = test_class.new

    mc2.run_bg; mc3.run_bg
    mc.add_member <+ [[mc2.ip_port], [mc3.ip_port]]
    mc.run_bg
    return [mc, mc2, mc3]
  end

  def test_be_mcast_done
    test_nodes = init_members(MC)
    mc = test_nodes[0]
    mc2 = test_nodes[1]
    mc3 = test_nodes[2]

    mc.sync_do{ mc.mcast_send <+ [[2, 'foobar']] }
    # Make sure messages propogate.
    mc.sync_do
    # Ensure messages were sent.
    mc.sync_do{ assert_equal(1, mc.mcast_done_perm.length) }
    mc.sync_do{ assert_equal(2, mc.mcast_done_perm.first.ident) }

    mc.stop
    mc2.stop
    mc3.stop
  end

  def test_re_mcast_not_done
    mc = RMC.new
    mc2 = RMC.new
    mc3 = URMC.new

    mc2.run_bg; mc3.run_bg
    mc.add_member <+ [[mc2.ip_port], [mc3.ip_port]]
    mc.run_bg

    mc.sync_do{ mc.mcast_send <+ [[2, 'foobar']] }
    # Make sure messages propogate.
    mc.sync_do
    # Ensure messages were not sent (because 1 not acked).
    mc.sync_do{ assert_equal(0, mc.mcast_done_perm.length) }

    mc.stop
    mc2.stop
    mc3.stop
  end

  def test_be_received
    test_nodes = init_members(MC)
    mc = test_nodes[0]
    mc2 = test_nodes[1]
    mc3 = test_nodes[2]

    mc.sync_do{ mc.mcast_send <+ [[2, 'foobar']] }
    # Make sure messages propogate.
    mc.sync_do
    # Ensure messages were received.
    mc.sync_do{ assert_equal(1, mc2.rcv_perm.length) }
    mc.sync_do{ assert_equal(1, mc3.rcv_perm.length) }
    mc.sync_do{ assert(mc2.rcv_perm.include?([2, 'foobar'])) }
    mc.sync_do{ assert(mc3.rcv_perm.include?([2, 'foobar'])) }

    mc.stop
    mc2.stop
    mc3.stop
  end

  def test_reliable_mcast_done
    test_nodes = init_members(RMC)
    mc = test_nodes[0]
    mc2 = test_nodes[1]
    mc3 = test_nodes[2]

    resps = mc.sync_callback(mc.mcast_send.tabname, [[1, 'foobar']], mc.mcast_done.tabname)
    assert_equal([[1]], resps.to_a.sort)

    mc.stop
    mc2.stop
    mc3.stop
  end

  def test_reliable_received
    test_nodes = init_members(RMC)
    mc = test_nodes[0]
    mc2 = test_nodes[1]
    mc3 = test_nodes[2]

    resps = mc.sync_callback(mc.mcast_send.tabname, [[1, 'foobar']], mc.mcast_done.tabname)

    assert_equal(mc2.rcv_perm.length, 1)
    assert_equal(mc3.rcv_perm.length, 1)
    assert(mc2.rcv_perm.include? [1, 'foobar'])
    assert(mc3.rcv_perm.include? [1, 'foobar'])

    mc.stop
    mc2.stop
    mc3.stop
  end
end
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                