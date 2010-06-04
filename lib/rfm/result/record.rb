module Rfm
  
  # The Record object represents a single FileMaker record. You typically get them from ResultSet objects.
  # For example, you might use a Layout object to find some records:
  #
  #   results = myLayout.find({"First Name" => "Bill"})
  #
  # The +results+ variable in this example now contains a ResultSet object. ResultSets are really just arrays of
  # Record objects (with a little extra added in). So you can get a record object just like you would access any 
  # typical array element:
  #
  #   first_record = results[0]
  #
  # You can find out how many record were returned:
  #
  #   record_count = results.size
  #
  # And you can of course iterate:
  # 
  #   results.each (|record|
  #     // you can work with the record here
  #   )
  #
  # =Accessing Field Data
  #
  # You can access field data in the Record object in two ways. Typically, you simply treat Record like a hash
  # (because it _is_ a hash...I love OOP). Keys are field names:
  # 
  #   first = myRecord["First Name"]
  #   last = myRecord["Last Name"]
  #
  # If your field naming conventions mean that your field names are also valid Ruby symbol named (ie: they contain only
  # letters, numbers, and underscores) then you can treat them like attributes of the record. For example, if your fields
  # are called "first_name" and "last_name" you can do this:
  #
  #   first = myRecord.first_name
  #   last = myRecord.last_name
  #
  # Note: This shortcut will fail (in a rather mysterious way) if your field name happens to match any real attribute
  # name of a Record object. For instance, you may have a field called "server". If you try this:
  # 
  #   server_name = myRecord.server
  # 
  # you'll actually set +server_name+ to the Rfm::Server object this Record came from. This won't fail until you try
  # to treat it as a String somewhere else in your code. It is also possible a future version of Rfm will include
  # new attributes on the Record class which may clash with your field names. This will cause perfectly valid code
  # today to fail later when you upgrade. If you can't stomach this kind of insanity, stick with the hash-like
  # method of field access, which has none of these limitations. Also note that the +myRecord[]+ method is probably
  # somewhat faster since it doesn't go through +method_missing+.
  #
  # =Accessing Repeating Fields
  #
  # If you have a repeating field, RFM simply returns an array:
  #
  #   val1 = myRecord["Price"][0]
  #   val2 = myRecord["Price"][1]
  #
  # In the above example, the Price field is a repeating field. The code puts the first repetition in a variable called 
  # +val1+ and the second in a variable called +val2+.
  #
  # =Accessing Portals
  #
  # If the ResultSet includes portals (because the layout it comes from has portals on it) you can access them
  # using the Record::portals attribute. It is a hash with table occurrence names for keys, and arrays of Record
  # objects for values. In other words, you can do this:
  #
  #   myRecord.portals["Orders"].each {|record|
  #     puts record["Order Number"]
  #   }
  #
  # This code iterates through the rows of the _Orders_ portal.
  # 
  # =Field Types and Ruby Types
  #
  # RFM automatically converts data from FileMaker into a Ruby object with the most reasonable type possible. The 
  # type are mapped thusly:
  #
  # * *Text* fields are converted to Ruby String objects
  # 
  # * *Number* fields are converted to Ruby BigDecimal objects (the basic Ruby numeric types have
  #   much less precision and range than FileMaker number fields)
  #
  # * *Date* fields are converted to Ruby Date objects
  #
  # * *Time* fields are converted to Ruby DateTime objects (you can ignore the date component)
  #
  # * *Timestamp* fields are converted to Ruby DateTime objects
  #
  # * *Container* fields are converted to Ruby URI objects
  #
  # =Attributes
  #
  # In addition to +portals+, the Record object has these useful attributes:
  #
  # * *record_id* is FileMaker's internal identifier for this record (_not_ any ID field you might have
  #   in your table); you need a +record_id+ to edit or delete a record
  #
  # * *mod_id* is the modification identifier for the record; whenever a record is modified, its +mod_id+
  #   changes so you can tell if the Record object you're looking at is up-to-date as compared to another
  #   copy of the same record
  class Record < Rfm::Utilities::HashWithIndifferentAccess
  
    attr_reader :record_id, :mod_id, :portals
  
    # Initializes a Record object. You really really never need to do this yourself. Instead, get your records
    # from a ResultSet object.
    def initialize(record, resultset, fields, portal=nil)
      @record_id = record['record-id']
      @mod_id = record['mod-id']
      @mods = {}
      @portals = Rfm::Utilities::HashWithIndifferentAccess.new
    
      related_sets = portal.nil? && resultset.include_portals ? record.xpath('relatedset') : []
    
      record.xpath('field').each do |field|
        field_name = field['name']
        field_name.sub!(Regexp.new(portal + '::'), '') if portal
        datum = []
        field.xpath('data').each do |x| 
          datum.push(coerce(x.inner_text, fields[field_name], resultset))
        end
      
        if datum.length == 1
          self[field_name] = datum[0]
        elsif datum.length == 0
          self[field_name] = nil
        else
          self[field_name] = datum
        end
      end
    
      unless related_sets.empty?
        related_sets.each do |relatedset|
          tablename, records = relatedset['table'], []

          relatedset.xpath('record').each do |record|
            records << Record.new(record, resultset, resultset.portal_meta[tablename], tablename)
          end
        
          @portals[tablename] = records
        end
      end
      @loaded = true
    end
  
    def coerce(value, field, resultset)
      return nil if (value == nil || value == '') && field.result != "text"
      case field.result
      when "text"      then value
      when "number"    then BigDecimal.new(value)
      when "date"      then Date.strptime(value, resultset.date_format)
      when "time"      then DateTime.strptime("1/1/-4712 " + value, "%m/%d/%Y #{resultset.time_format}")
      when "timestamp" then DateTime.strptime(value, resultset.timestamp_format)
      when "container" then #URI.parse("#{Rfm.scheme}://#{Rfm.host_name}:#{Rfm.port}#{value}") #TODO
      else nil
      end
    end

    # Saves local changes to the Record object back to Filemaker. For example:
    #
    #   myLayout.find({"First Name" => "Bill"}).each(|record|
    #     record["First Name"] = "Steve"
    #     record.save
    #   )
    #
    # This code finds every record with _Bill_ in the First Name field, then changes the first name to 
    # Steve.
    #
    # Note: This method is smart enough to not bother saving if nothing has changed. So there's no need
    # to optimize on your end. Just save, and if you've changed the record it will be saved. If not, no
    # server hit is incurred.
    def save
      if @mods.size > 0
        complete_edit = self.class.edit(self.record_id, @mods)[0]
        self.merge(complete_edit)
        @mods.clear
      end
    end

    # Like Record::save, except it fails (and raises an error) if the underlying record in FileMaker was
    # modified after the record was fetched but before it was saved. In other words, prevents you from
    # accidentally overwriting changes someone else made to the record.
    def save_if_not_modified
      self.merge(self.class.edit(@record_id, @mods, {:modification_id => @mod_id})[0]) if @mods.size > 0
      @mods.clear
    end
  
    # Gets the value of a field from the record. For example:
    #
    #   first = myRecord["First Name"]
    #   last = myRecord["Last Name"]
    #
    # This sample puts the first and last name from the record into Ruby variables.
    #
    # You can also update a field:
    #
    #   myRecord["First Name"] = "Sophia"
    #
    # When you do, the change is noted, but *the data is not updated in FileMaker*. You must call
    # Record::save or Record::save_if_not_modified to actually save the data.
    def []=(name, value)
      return super unless @loaded # keeps us from getting mods during initialization
      if self[name] != nil
        @mods[name] = value
      else
        raise Rfm::ParameterError.new("You attempted to modify a field called '#{name}' on the Rfm::Record object, but that field does not exist.")
      end
    end
  
    def method_missing (symbol, *attrs)
      # check for simple getter
      return self[symbol.to_s] if self.include?(symbol.to_s) 

      # check for setter
      symbol_name = symbol.to_s
      if symbol_name[-1..-1] == '=' && self.has_key?(symbol_name[0..-2])
        return @mods[symbol_name[0..-2]] = attrs[0]
      end
      super
    end
  
    def respond_to?(symbol, include_private = false)
      return true if self[symbol.to_s] != nil
      super
    end
  end
end