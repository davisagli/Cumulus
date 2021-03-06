/*
    Copyright (c) 2014, Salesforce.org
    All rights reserved.
    
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
    
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Salesforce.org nor the names of
      its contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.
 
    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
    COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; 
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
    POSSIBILITY OF SUCH DAMAGE.
*/
/**
* @author Salesforce.org
* @date 2014
* @group Address Management
* @description Trigger Handler on Contact for Address management 
* @async_support this trigger handler has been tested with async=true, and appears to not cause problems.
*/
public class ADDR_Contact_TDTM extends TDTM_Runnable {

    /*******************************************************************************************************
    * @description Trigger Handler on Contact that handles Address Management.
    * 	Rules:
    * 		inserting new contact - make their address a new default address, unless they say it is an override
    * 		updating an existing contact - make their address a new default address, unless they say it is an override
    * @param listNew the list of Contacts from trigger new. 
    * @param listOld the list of Contacts from trigger old. 
    * @param triggerAction which trigger event (BeforeInsert, AfterInsert, etc.). 
    * @param objResult the describe for Contacts 
    * @return dmlWrapper.  
    ********************************************************************************************************/
    public override DmlWrapper run(List<SObject> listNew, List<SObject> listOld, 
        TDTM_Runnable.Action triggerAction, Schema.DescribeSObjectResult objResult) {
        	
        DmlWrapper dmlWrapper = new DmlWrapper();        
        list<Contact> listConAddrSet = new list<Contact>(); 
        list<Contact> listConCreateAddr = new list<Contact>();
        map<Id, boolean> mapAddrIdIsOverride = new map<Id, boolean>();
        list<Contact> listConAddrReset = new list<Contact>();
        Map<Id,Account> mapAccountIdAccount = null;
        
		// bail out if address mgmt turned off.
        if (UTIL_CustomSettingsFacade.getContactsSettings().Household_Account_Addresses_Disabled__c)
        	return dmlWrapper;
                
        // Rules:
        // inserting new contact - make their address a new default address, unless they say it is an override
        // updating an existing contact - make their address a new default address, unless they say it is an override
        
        boolean isBefore = (triggerAction == TDTM_Runnable.Action.BeforeUpdate || triggerAction == TDTM_Runnable.Action.BeforeInsert);
        if (isBefore) { 
            // need to query account fields we need to look at
            Set<Id> setAccountId = new Set<Id>();
            for (SObject so : listNew) {
                Contact con = (Contact)so;
                if (con.AccountId != null)
                    setAccountId.add(con.AccountId);
            }
            mapAccountIdAccount = new Map<Id,Account>([select Id, npe01__SYSTEM_AccountType__c from Account where Id IN :setAccountId]);
        }        
       
        integer i = -1;        
        for (SObject so : listNew) {
            i++;  
            Contact con = (Contact)so;

            // we only support address management with HH Accounts being used
            if (con.AccountId == null)
                continue;
            if (!isBefore && (con.HHId__c != con.AccountId))
                continue;
            if (isBefore) {
                Account a = mapAccountIdAccount.get(con.AccountId);
                if (a.npe01__SYSTEM_AccountType__c != CAO_Constants.HH_ACCOUNT_TYPE)
                   continue;
            }                

            // BEFORE INSERT
            if (triggerAction == TDTM_Runnable.Action.BeforeInsert) {
                if (con.Current_Address__c != null) {
                	// remember which contacts will need their address set
                    listConAddrSet.add(con);
                    if (con.is_Address_Override__c)
                        // track which address's need their dates updated
                        mapAddrIdIsOverride.put(con.Current_Address__c, true);
                } else if (isContactAddressEmpty(con)) {
                	// if the contact has no address specified, pick up the hh default.
                    listConAddrReset.add(con);                	
                }
            }
            
            // BEFORE UPDATE
            if (triggerAction == TDTM_Runnable.Action.BeforeUpdate) {
            	// there can be four different types of changes we need to consider
            	// A. changes to isAddressOverride
            	// B. changes to CurrentAddress
            	// C. changes to MailingAddress fields
            	// D. changes to Account (ie switching accounts)
            	//
            	// that leads to 16 permutations! 
            	// (it's actually more permutations, since we need to take into account what
            	// the change in isAddressOverride or CurrentAddress is).
            	//
            	// A,B,C       if (CurrentAddress) refill to it, else update/new address object     
            	// A,!B,!C     if !isAddrOverride, refill contact from Default Address
            	// A,!B,C      if isAddrOverride, update/new addr object and refresh CurrentAddress, else update/new address object
            	// A,B,!C      if (CurrentAddress) refill to it, else refill from Default Address
            	// !A,B,C      if (CurrentAddress) refill to it, else update/new address object
            	// !A,!B,C     update/new address object
            	// !A,B,!C     if (CurrentAddress) refill to it, else refill from Default Address
            	// !A,!B,!C    nothing!
            	// *,*,*,D     if no override, refill from Default Address, else update/new address object    
            	//
            	// simplifying this to some precedence rules:
            	//     - if Account changes && no override, refill from Default Address
            	//     - if CurrentAddress changes to a new non-null value, refill to it.
            	//     - if MailingAddress field changes, update/new address object
                //     - if isAddressOverride changes to false, refill from Default Address
            	
            	Contact conOld = (Contact)listOld[i];
            	
            	// new highest priority! if Account changes... 
                if (conOld != null && con.AccountId != conOld.AccountId) {
                    // if no override, refill from the Default Address
            	    if (!con.is_Address_Override__c) {
                        listConAddrReset.add(con);
            	    } else { // create a new address on the account
                        listConCreateAddr.add(con);                    
            	    }                
            	} else {
            	
	                // highest priority. if they are changing to a new Current Address, refill from it.
	            	if (con.Current_Address__c != conOld.Current_Address__c && con.Current_Address__c != null) {
                        //UTIL_Debug.debug('****DJH: current address changed');            		
	                    listConAddrSet.add(con);
	                    if (con.is_Address_Override__c)
	                        // track which address's need their dates updated
	                        mapAddrIdIsOverride.put(con.Current_Address__c, true);                    
	            	}
	            	
	            	// second priority.  if they are clearing isAddressOverride, and no address fields change, refill from the Default Address
	            	if (con.is_Address_Override__c != conOld.is_Address_Override__c && !con.is_Address_Override__c && 
	            	    !isContactAddressChanged(con, conOld)) {
	                    listConAddrReset.add(con);
	                    if (conOld.Current_Address__c != null)
	                        // track which address's need their dates updated
	                        mapAddrIdIsOverride.put(conOld.Current_Address__c, false);
	            	}
	            	
	                // third priority.  if MailingAddress fields changed, update the existing address object or create a new one.
	                // this is handled in the next block, since we do it for both new contacts and updated contacts.
                }            	            	
            }
    
            // BEFORE UPDATE & AFTER UPDATE & BEFORE INSERT && AFTER INSERT
            // our functionality for dealing with contact address changes requires some trickery!
            // if the contact doesn't have an address override, we create (or match) a default address,
            // which requires us to do the work in the AfterUpdate (or else we can't propagate the default address).
            // but if the contact has an address override, we are supposed to create (or match) a non default address override.
            // in order to update the contact with the new address override's Id, we have to do it in the BeforeUpdate.
            if (triggerAction == TDTM_Runnable.Action.BeforeUpdate ||
               triggerAction == TDTM_Runnable.Action.BeforeInsert ||  
               triggerAction == TDTM_Runnable.Action.AfterInsert || 
               triggerAction == TDTM_Runnable.Action.AfterUpdate
               ) {
                // note that we detect whether the address change is coming from the address trigger,
                // in which case we don't want to create a new address.
                if (ADDR_Addresses_TDTM.hasRunAddrTrigger) {
                	//UTIL_Debug.debug('DJH**** stop Addr Trigger recursion in ADDR_Contact_TDTM');
                    continue;
                }

                // if the address changed, remember the contact we want to add a new address for    
                Contact conOld = (listOld != null ? (Contact)listOld[i] : null);
                if (isContactAddressChanged(con, conOld)) 
                    listConCreateAddr.add(con);
            }             
        }
        
        // set the mailing address for contacts who specify an address lookup or override
        if (listConAddrSet.size() > 0) {
            // to avoid pushing these address changes to the HH.
            ADDR_Addresses_TDTM.hasRunAddrTrigger = true;
            setConAddrFromLookup(listConAddrSet, dmlWrapper, triggerAction);
        }
        
        // reset the mailing address for contacts who no longer have an address override
        if (listConAddrReset.size() > 0) {
        	resetConAddr(listConAddrReset);
            // to avoid pushing these address changes to the HH.
            ADDR_Addresses_TDTM.hasRunAddrTrigger = true;
        }
        
        // update the Latest date fields on any address overrides
        if (mapAddrIdIsOverride.size() > 0) 
            updateAddrIsOverride(mapAddrIdIsOverride, dmlWrapper);
            
        // create any new Default Address objects
        if (listConCreateAddr.size() > 0)
            createAddrFromCon(listConCreateAddr, dmlWrapper, triggerAction);
            
        return dmlWrapper;    
    }

    /*******************************************************************************************************
    * @description for each contact, refresh its mailing address from its Address lookup
    * @param listCon the list of Contacts to update
    * @return void  
    ********************************************************************************************************/
    private void setConAddrFromLookup(list<Contact> listCon, DmlWrapper dmlWrapper, TDTM_Runnable.Action triggerAction) {
    	
    	list<Contact> listConCreateAddr = new list<Contact>();
    	set<Id> setAddrId = new set<Id>();
    	for (Contact con : listCon) {
    		if (con.Current_Address__c != null)
    		  setAddrId.add(con.Current_Address__c);
    	}
    
        map<Id, Address__c> mapAddrIdAddr = new map<Id, Address__c>([select Id, Address_Type__c, Household_Account__c, 
            MailingStreet__c, MailingStreet2__c, MailingCity__c, MailingState__c, Geolocation__Latitude__s, Geolocation__Longitude__s, 
            MailingPostalCode__c, MailingCountry__c from Address__c where Id in :setAddrId]);
            
        //UTIL_Debug.debug('****DJH: setConAddrFromLookup mapAddrIdAddr: ' + mapAddrIdAddr);
            
        for (Contact con : listCon) {
            Address__c addr = mapAddrIdAddr.get(con.Current_Address__c);
            if (addr != null) {
                ADDR_Addresses_TDTM.copyAddressAddrSObj(addr, con, 'Mailing', 'npe01__Primary_Address_Type__c');

            	// deal with any address coming from a different account,
            	// which we need to treat as a creation instead.
            	if (addr.Household_Account__c != con.AccountId) {
            	   //UTIL_Debug.debug('****DJH address not on same account, so add to create list: con' + con);
            	   listConCreateAddr.add(con);
            	}
            }
        }
        
        if (listConCreateAddr.size() > 0)
            createAddrFromCon(listConCreateAddr, dmlWrapper, triggerAction);
             	
    }

    /*******************************************************************************************************
    * @description compares two contacts' addresses
    * @param con1 a Contact
    * @param con2 a Contact
    * @return boolean. true if the Mailing Address fields have changed 
    ********************************************************************************************************/
    private boolean isContactAddressChanged(Contact con1, Contact con2) {
    	// if both null, no change
        if (con1 == null && con2 == null) 
           return false;

        // if one null, make sure other has at least one address field set
        if (con1 == null || con2 == null) {
        	if (con1 == null) 
        	   con1 = con2;
        	return (!isContactAddressEmpty(con1) ||
	           con1.npe01__Primary_Address_Type__c != null);
        }
        
        // both provided, so look for at least one change between address fields
        boolean isChanged = 
           !ADDR_Addresses_TDTM.equalsCaseSensitive(con1.MailingStreet, con2.MailingStreet) ||
           !ADDR_Addresses_TDTM.equalsCaseSensitive(con1.MailingCity, con2.MailingCity) ||
           !ADDR_Addresses_TDTM.equalsCaseSensitive(con1.MailingState, con2.MailingState) ||
           !ADDR_Addresses_TDTM.equalsCaseSensitive(con1.MailingPostalCode, con2.MailingPostalCode) ||
           !ADDR_Addresses_TDTM.equalsCaseSensitive(con1.MailingCountry, con2.MailingCountry) ||
           !ADDR_Addresses_TDTM.equalsCaseSensitive(con1.npe01__Primary_Address_Type__c, con2.npe01__Primary_Address_Type__c);
           
        if (!isChanged && ADDR_Addresses_TDTM.isStateCountryPicklistsEnabled) {
            isChanged = 
                !ADDR_Addresses_TDTM.equalsCaseSensitive(string.valueOf(con1.get('MailingStateCode')), string.valueOf(con2.get('MailingStateCode'))) || 
                !ADDR_Addresses_TDTM.equalsCaseSensitive(string.valueOf(con1.get('MailingCountryCode')), string.valueOf(con2.get('MailingCountryCode')));
        }    
        return isChanged;   
    }
    
    /*******************************************************************************************************
    * @description returns whether the contact's mailing address is empty
    * @param con1 a Contact
    * @return boolean. true if the Mailing Address fields are all empty 
    ********************************************************************************************************/
    private boolean isContactAddressEmpty(Contact con1) {
        boolean isEmpty = 
            con1.MailingStreet == null &&
            con1.MailingCity == null &&
            con1.MailingState == null &&
            con1.MailingPostalCode == null &&
            // note that we decided to ignore country so that a default value won't create unnecessary address objects
            (con1.MailingCountry == null || ADDR_Addresses_TDTM.isStateCountryPicklistsEnabled) &&
            // only test StateCode if picklists enabled.
            (!ADDR_Addresses_TDTM.isStateCountryPicklistsEnabled || con1.get('MailingStateCode') == null);
        return isEmpty;   
           
    }
       
    /*******************************************************************************************************
    * @description Creates a new address or matches an existing one, for each Contact.
    * This routine is called both by BeforeInsert/Update and AfterInsert/Update.
    * when pushing a new default address, we need to do it in the AfterInsert/Update.
    * otherwise we want to do it in the BeforeInsert/Update so we can update the contacts' info now.
    * @param listConAll the list of Contacts
    * @param dmlWrapper to hold the Addresses that need inserting/updating 
    * @param triggerAction which trigger event (BeforeInsert, AfterInsert, etc.). 
    * @return void  
    ********************************************************************************************************/
    private static void createAddrFromCon(list<Contact> listConAll, DmlWrapper dmlWrapper,  TDTM_Runnable.Action triggerAction) {
    	
    	//UTIL_Debug.debug('****DJH: createAddrFromCon listConAll: ' + listConAll);
    	
    	// Strategy:
    	// create a new (unsaved) address for each contact.
    	// see if there is an existing address that matches each new address.
    	// 
    	// for existing addresses we match
    	//     process during BeforeInsert/Update
    	//     update appropriate fields on contact
    	//
    	// for new addresses that won't be a default (ie, the contact has override set)
        //     process during BeforeInsert/Update
    	//     create the address now
        //     update appropriate fields on contact
    	//
    	// for new addresses that will be a default address
        //     process during AfterInsert/Update
    	//     mark the new address as default
    	//     put it on dmlWrapper
    	//
    	
    	map<Contact, Address__c> mapConAddr = new map<Contact, Address__c>();
    	list<Contact> listCon = new list<Contact>();
    	boolean isBefore = (triggerAction == TDTM_Runnable.Action.BeforeInsert || triggerAction == TDTM_Runnable.Action.BeforeUpdate);
    	
        for (Contact con : listConAll) {
            listCon.add(con);
        	Address__c addr = new Address__c();
        	addr.Household_Account__c = con.AccountId;
        	addr.Default_Address__c = !con.is_Address_Override__c;
        	addr.Latest_Start_Date__c = system.today();
        	addr.Latest_End_Date__c = null;        	
        	ADDR_Addresses_TDTM.copyAddressStdSObjAddr(con, 'Mailing', addr, con.npe01__Primary_Address_Type__c);
            mapConAddr.put(con, addr);
        }

        // look for duplicates for our proposed new addresses        
        map<Address__c, Address__c> mapAddrDupAddr = ADDR_Addresses_TDTM.findDuplicateAddresses(mapConAddr.values());
        
        // maps & lists to keep track of the addresses we must insert or update
        map<Contact, Address__c> mapConAddrInsertNow = new map<Contact, Address__c>();
        list<Address__c> listAddrUpdateDefault = new list<Address__c>();
        list<Address__c> listAddrInsertDefault = new list<Address__c>();
        
        for (Contact con : listCon) {
            Address__c addrNew = mapConAddr.get(con);
            Address__c addrDup = mapAddrDupAddr.get(addrNew);
            
            // if found a match
            if (addrDup != null) {
            	// record the match in the contact
            	if (isBefore) {
                    con.Current_Address__c = addrDup.Id;
            	} else { 	                
	                // if it is a fuzzy match, not exact, then we want to update the existing address.
	                if (ADDR_Addresses_TDTM.isAddressChanged(addrNew, addrDup, true)) {
	                    ADDR_Addresses_TDTM.copyAddressObj(addrNew, addrDup);
	                    if (!con.is_Address_Override__c && !addrDup.Default_Address__c)
	                        addrDup.Default_Address__c = true;
	                    listAddrUpdateDefault.add(addrDup);
	                }                  
	                // exact match. we aren't specifying override, so the address should become the new hh default address
	                else if (!con.is_Address_Override__c && !addrDup.Default_Address__c) {
	                	addrDup.Default_Address__c = true;
	                	listAddrUpdateDefault.add(addrDup);
	                }
                }
            }

            // no match found, and its an override just for this contact
            else if (isBefore && con.is_Address_Override__c) {
            	// put it on the list of addresss to create now
                mapConAddrInsertNow.put(con, addrNew);        	
            }
            
            // no match, not an override, make it a new default hh address
            else if (!isBefore) {
                addrNew.Default_Address__c = true;
                listAddrInsertDefault.add(addrNew);                
            }
        }
        
        if (mapConAddrInsertNow.size() > 0 && isBefore) {
	        insert mapConAddrInsertNow.values();
	        for (Contact con : mapConAddrInsertNow.keySet()) {
	            Address__c addr = mapConAddrInsertNow.get(con);
	            con.Current_Address__c = addr.Id;
	        }        
        }    
        
        if (listAddrUpdateDefault.size() > 0 && !isBefore) {
            for (Address__c addr : listAddrUpdateDefault)
                dmlWrapper.objectsToUpdate.add(addr);
        }
            
        if (listAddrInsertDefault.size() > 0 && !isBefore) {
            dmlWrapper.objectsToInsert.addAll((list<SObject>)listAddrInsertDefault);
        }
    }

    /*******************************************************************************************************
    * @description Updates the Latest date fields on any address overrides
    * @param mapAddrIdIsOverride map of Address Id's to an isOverride boolean
    * @param dmlWrapper to hold the Addresses that need updating 
    * @return void  
    ********************************************************************************************************/
    private void updateAddrIsOverride(Map<Id, boolean> mapAddrIdIsOverride, DmlWrapper dmlWrapper) {

        for (ID id : mapAddrIdIsOverride.keySet()) {
            Address__c addr = new Address__c();
            addr.Id = id;
            if (mapAddrIdIsOverride.get(id) == true) {
            	addr.Latest_Start_Date__c = system.today();
            	addr.Latest_End_Date__c = null;
            } else {
                addr.Latest_End_Date__c = system.today();
            }
            dmlWrapper.objectsToUpdate.add(addr);
        }        
    }

    /*******************************************************************************************************
    * @description Finds each Contact's HH current address (either Default or Seasonal) and updates 
    * the contact's address fields
    * @param listCon list of Contacts 
    * @return void  
    ********************************************************************************************************/
    private static void resetConAddr(list<Contact> listCon) {
        if (listCon == null || listCon.size() == 0) return;
        
        map<Id, Address__c> mapAccIdAddr = new map<Id, Address__c>();
        for (Contact con : listCon) 
            mapAccIdAddr.put(con.AccountId, null);
            
        // get the default and seasonal address for each HH
        map<Id, ADDR_Addresses_TDTM.HHInfo> mapAccIdHHInfo = ADDR_Addresses_TDTM.refreshCurrentHHAddress(mapAccIdAddr, null, true);
        
        // reset the Contact's address fields with the appropriate address
        for (Contact con : listCon) {
        	ADDR_Addresses_TDTM.HHInfo hhinfo = mapAccIdHHInfo.get(con.AccountId);
        	if (hhinfo != null) {
        		Address__c addr = hhinfo.addrSeasonal;
        		if (addr == null)
        		  addr = hhinfo.addrDefault;
                if (addr != null) {
                	con.Current_Address__c = addr.Id;
                    ADDR_Addresses_TDTM.copyAddressAddrSObj(addr, con, 'Mailing', 'npe01__Primary_Address_Type__c');
                }
        	}
        }         
    }

    /*******************************************************************************************************
    * @description For these merge winner Contacts, update their address if using default, or if using
    * an override, copy the override to the household (avoiding dupes);
    * @param listCon list of Contacts 
    * @return void  
    public static void handleContactMergeAddresses(list<Contact> listCon) {
        TDTM_Runnable.DmlWrapper dmlWrapper = new TDTM_Runnable.DmlWrapper();
        list<Contact> listConAddrReset = new list<Contact>();
        list<Contact> listConCreateAddr = new list<Contact>();
 
        for (Contact con : listCon) {
	         // if no override, refill from the Default Address
	        if (!con.is_Address_Override__c) {
	            listConAddrReset.add(con);
	        } else { // create a new address on the account
	            listConCreateAddr.add(con);                    
	        }
        }                
    
         // reset the mailing address for contacts who no longer have an address override
        if (listConAddrReset.size() > 0) {
            resetConAddr(listConAddrReset);
            // to avoid pushing these address changes to the HH.
            ADDR_Addresses_TDTM.hasRunAddrTrigger = true;
            // update them
            dmlWrapper.objectsToUpdate.addAll((list<SObject>)listConAddrReset);
        }
 
         // create new Address override objects
        if (listConCreateAddr.size() > 0) {
            createAddrFromCon(listConCreateAddr, dmlWrapper, TDTM_Runnable.Action.BeforeUpdate);
        }
        
        TDTM_TriggerHandler.ProcessDml(dmlWrapper);
    }
    ********************************************************************************************************/

}