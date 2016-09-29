module Synthea
  module Output
    module FhirRecord
      SHR_EXT = 'http://standardhealthrecord.org/fhir/extensions/'.freeze

      def self.convert_to_fhir(entity)
        synthea_record = entity.record_synthea
        indices = { observations: 0, conditions: 0, procedures: 0, immunizations: 0, careplans: 0, medications: 0 }
        fhir_record = FHIR::Bundle.new
        fhir_record.type = 'collection'
        patient = basic_info(entity, fhir_record)
        synthea_record.encounters.each do |encounter|
          curr_encounter = encounter(encounter, fhir_record, patient)
          [:conditions, :observations, :procedures, :immunizations, :careplans, :medications].each do |attribute|
            entry = synthea_record.send(attribute)[indices[attribute]]
            while entry && entry['time'] <= encounter['time']
              method = entry['fhir']
              method = attribute.to_s if method.nil?
              send(method, entry, fhir_record, patient, curr_encounter)
              indices[attribute] += 1
              entry = synthea_record.send(attribute)[indices[attribute]]
            end
          end
        end
        fhir_record
      end

      def self.basic_info(entity, fhir_record)
        if entity[:race] == :hispanic
          race_fhir = :other
          ethnicity_fhir = entity[:ethnicity]
        else
          race_fhir = entity[:ethnicity]
          ethnicity_fhir = :nonhispanic
        end
        resource_id = SecureRandom.uuid.to_s.strip
        patient_resource = FHIR::Patient.new('id' => resource_id,
                                             'identifier' => [{
                                               'system' => 'https://github.com/synthetichealth/synthea',
                                               'value' => entity.record_synthea.patient_info[:uuid]
                                             }],
                                             'name' => [{ 'given' => [entity[:name_first]],
                                                          'family' => [entity[:name_last]],
                                                          'use' => 'official' }],
                                             'telecom' => [{ 'system' => 'phone', 'use' => 'home', 'value' => entity[:telephone],
                                                             'extension' => [{ 'url' => "#{SHR_EXT}okayToLeaveMessage", 'valueBoolean' => true }] }],
                                             'gender' => ('male' if entity[:gender] == 'M') || ('female' if entity[:gender] == 'F'),
                                             'birthDate' => convert_fhir_date_time(entity.event(:birth).time),
                                             'address' => [FHIR::Address.new(entity[:address])],
                                             'extension' => [
                                               # race
                                               {
                                                 'url' => 'http://hl7.org/fhir/StructureDefinition/us-core-race',
                                                 'valueCodeableConcept' => {
                                                   'text' => 'race',
                                                   'coding' => [{
                                                     'display' => race_fhir.to_s.capitalize,
                                                     'code' => RACE_ETHNICITY_CODES[race_fhir],
                                                     'system' => 'http://hl7.org/fhir/v3/Race'
                                                   }]
                                                 }
                                               },
                                               # ethnicity
                                               {
                                                 'url' => 'http://hl7.org/fhir/StructureDefinition/us-core-ethnicity',
                                                 'valueCodeableConcept' => {
                                                   'text' => 'ethnicity',
                                                   'coding' => [{
                                                     'display' => ethnicity_fhir.to_s.capitalize,
                                                     'code' => RACE_ETHNICITY_CODES[ethnicity_fhir],
                                                     'system' => 'http://hl7.org/fhir/v3/Ethnicity'
                                                   }]
                                                 }
                                               },
                                               {
                                                 'url' => "#{SHR_EXT}wkt-geospatialpoint",
                                                 'valueString' => "POINT (#{entity[:coordinates_address].x} #{entity[:coordinates_address].y})"
                                               },
                                               # place of birth
                                               {
                                                 'url' => "#{SHR_EXT}placeOfBirth",
                                                 'valueAddress' => FHIR::Address.new(entity[:birth_place]).to_hash
                                               },
                                               # mother's maiden name
                                               {
                                                 'url' => 'http://hl7.org/fhir/StructureDefinition/patient-mothersMaidenName',
                                                 'valueString' => entity[:name_mother]
                                               },
                                               # father's name
                                               {
                                                 'url' => "#{SHR_EXT}fathersName",
                                                 'valueString' => entity[:name_father]
                                               }
                                             ])
        # add optional patient name information
        patient_resource.name.first.prefix << entity[:name_prefix] if entity[:name_prefix]
        patient_resource.name.first.suffix << entity[:name_suffix] if entity[:name_suffix]
        if entity[:name_maiden]
          patient_resource.name << FHIR::HumanName.new('given' => [entity[:name_first]],
                                                       'family' => [entity[:name_maiden]], 'use' => 'maiden')
        end
        # add marital status if present
        if entity[:marital_status]
          patient_resource.maritalStatus = FHIR::CodeableConcept.new('coding' => [{ 'system' => 'http://hl7.org/fhir/v3/MaritalStatus', 'code' => entity[:marital_status] }])
        end
        # add information about twins/triplets if applicable
        if entity[:multiple_birth]
          patient_resource.multipleBirthInteger = entity[:multiple_birth]
          patient_resource.extension << FHIR::Extension.new('url' => "#{SHR_EXT}multipleBirth",
                                                            'valueCode' => 'Multiple')
        else
          patient_resource.multipleBirthBoolean = false
        end
        # add additional identification numbers if applicable
        if entity[:identifier_ssn]
          patient_resource.identifier << FHIR::Identifier.new('type' => { 'coding' => [{ 'system' => 'http://hl7.org/fhir/identifier-type', 'code' => 'SB' }] },
                                                              'system' => 'http://hl7.org/fhir/sid/us-ssn', 'value' => entity[:identifier_ssn].delete('-'))
        end
        if entity[:identifier_drivers]
          patient_resource.identifier << FHIR::Identifier.new('type' => { 'coding' => [{ 'system' => 'http://hl7.org/fhir/v2/0203', 'code' => 'DL' }] },
                                                              'system' => 'urn:oid:2.16.840.1.113883.4.3.25', 'value' => entity[:identifier_drivers])
        end
        if entity[:identifier_passport]
          patient_resource.identifier << FHIR::Identifier.new('type' => { 'coding' => [{ 'system' => 'http://hl7.org/fhir/v2/0203', 'code' => 'PPN' }] },
                                                              'system' => "#{SHR_EXT}passportNumber", 'value' => entity[:identifier_passport])
        end
        # add biometric data
        if entity[:fingerprint]
          patient_resource.photo << FHIR::Attachment.new('contentType' => 'image/png', 'title' => 'Biometrics.Fingerprint',
                                                         'data' => Base64.strict_encode64(entity[:fingerprint].to_blob))
        end
        # record death if applicable
        unless entity[:is_alive]
          patient_resource.deceasedDateTime = convert_fhir_date_time(entity.record_synthea.patient_info[:deathdate], 'time')
        end

        entry = FHIR::Bundle::Entry.new
        entry.fullUrl = "urn:uuid:#{resource_id}"
        entry.resource = patient_resource
        fhir_record.entry << entry
        entry
      end

      def self.condition(condition, fhir_record, patient, encounter)
        resource_id = SecureRandom.uuid
        condition_data = COND_LOOKUP[condition['type']]
        fhir_condition = FHIR::Condition.new('id' => resource_id,
                                             'subject' => { 'reference' => patient.fullUrl.to_s },
                                             'code' => {
                                               'coding' => [{
                                                 'code' => condition_data[:codes]['SNOMED-CT'][0],
                                                 'display' => condition_data[:description],
                                                 'system' => 'http://snomed.info/sct'
                                               }]
                                             },
                                             'verificationStatus' => 'confirmed',
                                             'clinicalStatus' => 'active',
                                             'onsetDateTime' => convert_fhir_date_time(condition['time'], 'time'),
                                             'context' => { 'reference' => encounter.fullUrl.to_s })
        if condition['end_time']
          fhir_condition.abatementDateTime = convert_fhir_date_time(condition['end_time'], 'time')
        end
        entry = FHIR::Bundle::Entry.new
        entry.fullUrl = "urn:uuid:#{resource_id}"
        entry.resource = fhir_condition
        fhir_record.entry << entry
      end

      def self.encounter(encounter, fhir_record, patient)
        resource_id = SecureRandom.uuid.to_s
        encounter_data = ENCOUNTER_LOOKUP[encounter['type']]
        fhir_encounter = FHIR::Encounter.new('id' => resource_id,
                                             'status' => 'finished',
                                             'class' => { 'code' => encounter_data[:class] },
                                             'type' => [{ 'coding' => [{ 'code' => encounter_data[:codes]['SNOMED-CT'][0], 'system' => 'http://snomed.info/sct' }], 'text' => encounter_data[:description] }],
                                             'patient' => { 'reference' => patient.fullUrl.to_s },
                                             'period' => { 'start' => convert_fhir_date_time(encounter['time'], 'time'), 'end' => convert_fhir_date_time(encounter['time'] + 15.minutes, 'time') })
        entry = FHIR::Bundle::Entry.new
        entry.fullUrl = "urn:uuid:#{resource_id}"
        entry.resource = fhir_encounter
        fhir_record.entry << entry
        entry
      end

      def self.allergy(allergy, fhir_record, patient, _encounter)
        snomed_code = COND_LOOKUP[allergy['type']][:codes]['SNOMED-CT'][0]
        allergy = FHIR::AllergyIntolerance.new('attestedDate' => convert_fhir_date_time(allergy['time'], 'time'),
                                               'status' => 'active-confirmed',
                                               'type' => 'allergy',
                                               'category' => 'food',
                                               'criticality' => %w(low high).sample,
                                               'patient' => { 'reference' => patient.fullUrl.to_s },
                                               'code' => { 'coding' => [{
                                                 'code' => snomed_code,
                                                 'display' => allergy['type'].to_s.split('food_allergy_')[1],
                                                 'system' => 'http://snomed.info/sct'
                                               }] })
        entry = FHIR::Bundle::Entry.new
        entry.resource = allergy
        fhir_record.entry << entry
      end

      def self.observation(observation, fhir_record, patient, encounter)
        obs_data = OBS_LOOKUP[observation['type']]
        entry = FHIR::Bundle::Entry.new
        resource_id = SecureRandom.uuid
        entry.fullUrl = "urn:uuid:#{resource_id}"
        entry.resource = FHIR::Observation.new('id' => resource_id,
                                               'status' => 'final',
                                               'code' => {
                                                 'coding' => [{ 'system' => 'http://loinc.org', 'code' => obs_data[:code], 'display' => obs_data[:description] }]
                                               },
                                               'subject' => { 'reference' => patient.fullUrl.to_s },
                                               'encounter' => { 'reference' => encounter.fullUrl.to_s },
                                               'effectiveDateTime' => convert_fhir_date_time(observation['time'], 'time'),
                                               'valueQuantity' => { 'value' => observation['value'], 'unit' => obs_data[:unit] })
        fhir_record.entry << entry
      end

      def self.multi_observation(multi_obs, fhir_record, patient, encounter)
        entry = FHIR::Bundle::Entry.new
        resource_id = SecureRandom.uuid
        entry.fullUrl = "urn:uuid:#{resource_id}"
        observations = fhir_record.entry.pop(multi_obs['value'])
        multi_data = OBS_LOOKUP[multi_obs['type']]
        fhir_observation = FHIR::Observation.new('id' => resource_id,
                                                 'status' => 'final',
                                                 'code' => {
                                                   'coding' => [{ 'system' => 'http://loinc.org', 'code' => multi_data[:code], 'display' => multi_data[:description] }]
                                                 },
                                                 'subject' => { 'reference' => patient.fullUrl.to_s },
                                                 'encounter' => { 'reference' => encounter.fullUrl.to_s },
                                                 'effectiveDateTime' => convert_fhir_date_time(multi_obs['time'], 'time'))
        observations.each do |obs|
          fhir_observation.component << FHIR::Observation::Component.new('code' => obs.resource.code.to_hash, 'valueQuantity' => obs.resource.valueQuantity.to_hash)
        end
        entry.resource = fhir_observation
        fhir_record.entry << entry
      end

      def self.diagnostic_report(report, fhir_record, patient, encounter)
        entry = FHIR::Bundle::Entry.new
        resource_id = SecureRandom.uuid
        entry.fullUrl = "urn:uuid:#{resource_id}"
        report_data = OBS_LOOKUP[report['type']]
        entry.resource = FHIR::DiagnosticReport.new('id' => resource_id,
                                                    'status' => 'final',
                                                    'code' => {
                                                      'coding' => [{ 'system' => 'http://loinc.org', 'code' => report_data[:code], 'display' => report_data[:description] }]
                                                    },
                                                    'subject' => { 'reference' => patient.fullUrl.to_s },
                                                    'encounter' => { 'reference' => encounter.fullUrl.to_s },
                                                    'effectiveDateTime' => convert_fhir_date_time(report['time'], 'time'),
                                                    'issued' => convert_fhir_date_time(report['time'], 'time'),
                                                    'performer' => [{ 'display' => 'Hospital Lab' }])
        entry.resource.result = []
        obs_entries = fhir_record.entry.last(report['numObs'])
        obs_entries.each do |e|
          entry.resource.result << FHIR::Reference.new('reference' => e.fullUrl.to_s, 'display' => e.resource.code.coding.first.display)
        end
        fhir_record.entry << entry
      end

      def self.procedure(procedure, fhir_record, patient, encounter)
        reason = fhir_record.entry.find { |e| e.resource.is_a?(FHIR::Condition) && e.resource.code.coding.find { |c| c.code == procedure['reason'] } }
        proc_data = PROCEDURE_LOOKUP[procedure['type']]
        fhir_procedure = FHIR::Procedure.new('subject' => { 'reference' => patient.fullUrl.to_s },
                                             'status' => 'completed',
                                             'code' => {
                                               'coding' => [{ 'code' => proc_data[:codes]['SNOMED-CT'][0], 'display' => proc_data[:description], 'system' => 'http://snomed.info/sct' }],
                                               'text' => proc_data[:description]
                                             },
                                             # 'reasonReference' => { 'reference' => reason.resource.id },
                                             # 'performer' => { 'reference' => doctor_no_good },
                                             'performedDateTime' => convert_fhir_date_time(procedure['time'], 'time'),
                                             'encounter' => { 'reference' => encounter.fullUrl.to_s })
        fhir_procedure.reasonReference = FHIR::Reference.new('reference' => reason.fullUrl.to_s, 'display' => reason.resource.code.text) if reason

        entry = FHIR::Bundle::Entry.new
        entry.resource = fhir_procedure
        fhir_record.entry << entry
      end

      def self.immunization(imm, fhir_record, patient, encounter)
        immunization = FHIR::Immunization.new('status' => 'completed',
                                              'date' => convert_fhir_date_time(imm['time'], 'time'),
                                              'vaccineCode' => {
                                                'coding' => [IMM_SCHEDULE[imm['type']][:code]]
                                              },
                                              'patient' => { 'reference' => patient.fullUrl.to_s },
                                              'wasNotGiven' => false,
                                              'reported' => false,
                                              'encounter' => { 'reference' => encounter.fullUrl.to_s })
        entry = FHIR::Bundle::Entry.new
        entry.resource = immunization
        fhir_record.entry << entry
      end

      def self.careplans(plan, fhir_record, patient, encounter)
        careplan_data = CAREPLAN_LOOKUP[plan['type']]
        reasons = []
        plan['reasons'].each do |reason|
          reason_code = COND_LOOKUP[reason][:codes]['SNOMED-CT'][0]
          r = fhir_record.entry.find { |e| e.resource.is_a?(FHIR::Condition) && reason_code == e.resource.code.coding[0].code }
          reasons << r unless r.nil?
        end

        careplan = FHIR::CarePlan.new('subject' => { 'reference' => patient.fullUrl.to_s },
                                      'context' => { 'reference' => encounter.fullUrl.to_s },
                                      'period' => { 'start' => convert_fhir_date_time(plan['start_time']) },
                                      'category' => [{
                                        'coding' => [{
                                          'code' => careplan_data[:codes]['SNOMED-CT'][0],
                                          'display' => careplan_data[:description],
                                          'system' => 'http://snomed.info/sct'
                                        }]
                                      }],
                                      'activity' => [],
                                      'addresses' => [])
        reasons.each do |r|
          careplan.addresses << FHIR::Reference.new('reference' => r.fullUrl.to_s) unless reasons.nil? || reasons.empty?
        end
        if plan['stop']
          careplan.period.end = convert_fhir_date_time(plan['stop'])
          careplan.status = 'completed'
        else
          careplan.status = 'active'
        end
        plan['activities'].each do |activity|
          activity_data = CAREPLAN_LOOKUP[activity]
          careplan.activity << FHIR::CarePlan::Activity.new('detail' => {
                                                              'code' => {
                                                                'coding' => [{
                                                                  'code' => activity_data[:codes]['SNOMED-CT'][0],
                                                                  'display' => activity_data[:description],
                                                                  'system' => 'http://snomed.info/sct'
                                                                }]
                                                              }
                                                            })
        end
        entry = FHIR::Bundle::Entry.new
        entry.resource = careplan
        fhir_record.entry << entry
      end

      def self.medications(prescription, fhir_record, patient, encounter)
        med_data = MEDICATION_LOOKUP[prescription['type']]
        reasons = []
        prescription['reasons'].each do |reason|
          reason_code = COND_LOOKUP[reason][:codes]['SNOMED-CT'][0]
          r = fhir_record.entry.find { |e| e.resource.is_a?(FHIR::Condition) && reason_code == e.resource.code.coding[0].code }
          reasons << r unless r.nil?
        end
        med_order = FHIR::MedicationOrder.new('medicationCodeableConcept' => {
                                                'coding' => [{
                                                  'code' => med_data[:codes]['RxNorm'][0],
                                                  'display' => med_data[:description],
                                                  'system' => 'http://www.nlm.nih.gov/research/umls/rxnorm'
                                                }]
                                              },
                                              'patient' => { 'reference' => patient.fullUrl.to_s },
                                              'encounter' => { 'reference' => encounter.fullUrl.to_s },
                                              'dateWritten' => convert_fhir_date_time(prescription['start_time']),
                                              'reasonReference' => [],
                                              'eventHistory' => [])
        reasons.each do |r|
          med_order.reasonReference << FHIR::Reference.new('reference' => r.fullUrl.to_s)
        end
        if prescription['stop']
          med_order.status = 'stopped'

          event = FHIR::MedicationOrder::EventHistory.new('status' => 'stopped',
                                                          'dateTime' => convert_fhir_date_time(prescription['stop']))

          reason_data = REASON_LOOKUP[prescription['stop_reason']]
          if reason_data
            event.reason = FHIR::CodeableConcept.new('coding' => [{
                                                       'code' => reason_data[:codes]['SNOMED-CT'][0],
                                                       'display' => reason_data[:description],
                                                       'system' => 'http://snomed.info/sct'
                                                     }])
          end
          med_order.eventHistory << event
        else
          med_order.status = 'active'
        end
        entry = FHIR::Bundle::Entry.new
        entry.resource = med_order
        fhir_record.entry << entry
      end

      def self.convert_fhir_date_time(date, option = nil)
        date = Time.at(date) if date.is_a?(Integer)
        if option == 'time'
          x = date.to_s.sub(' ', 'T')
          x = x.sub(' ', '')
          x = x.insert(-3, ':')
          return Regexp.new(FHIR::PRIMITIVES['dateTime']['regex']).match(x.to_s).to_s
        else
          return Regexp.new(FHIR::PRIMITIVES['date']['regex']).match(date.to_s).to_s
        end
      end
    end
  end
end
