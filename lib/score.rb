require 'note'
require 'util'
require 'singleton'

module Aleatoric

class Score
  attr_reader :notes

  def initialize
    @notes = []
    @active = false
  end
  
  def <<(n)
    if n.is_array? # Defined on Object in util.rb
      n.each {|note| @notes << note}
    elsif n
      @notes << n
    end
  end
    
  def last
    @notes.last
  end
  
  def active?(flag=nil)
    @active = flag unless flag == nil
    @active
  end
  
  def method_missing_handler(name, val)
    last.method_missing(name, val)
  end
  
  def to_s
    s = ""
    @notes.each {|note| s << note.to_s}
    s << @dummy.to_s # TODO get rid of
    s
  end
  
  # TODO get rid of
  def dummy(arg)
    @dummy = arg
    @dummy
  end
end

class ScoreWriter < Score
  include Singleton
end

class Phrase < Score
end

class Player < Score
end

end