package site.ycsb.db;

import org.apache.iceberg.Schema;
import org.apache.iceberg.Transaction;
import org.apache.iceberg.catalog.TableIdentifier;
import site.ycsb.ByteArrayByteIterator;
import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;

import java.util.*;

public class CatalogClient extends DB {

  Catalog catalog;

  private Optional<TableIdentifier> getIdentifierFromTableName(String tableName){
    return catalog.listTables(EMPTY_NAMESPACE).stream()
        .filter(identifier -> identifier.name().equals(tableName))
        .findAny();
  }

  @Override
  public void init() throws DBException {
    // we should initialize Catalog here to some concrete implementation?
  }

//  @Override
//  public void cleanup() throws DBException {
//    System.out.println("cleanup");
//  }

  /**
   * Read a record from the database. Each field/value pair from the result will be stored in a HashMap.
   *
   * @param table The name of the table
   * @param key The record key of the record to read.
   * @param fields The list of fields to read, or null for all of them
   * @param result A HashMap of field/value pairs for the result
   * @return The result of the operation.
   */
  public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result){
    // we don't care about reads?
    return Status.OK;
  }

  /**
   * Perform a range scan for a set of records in the database. Each field/value pair from the result will be stored
   * in a HashMap.
   *
   * @param table The name of the table
   * @param startkey The record key of the first record to read.
   * @param recordcount The number of records to read
   * @param fields The list of fields to read, or null for all of them
   * @param result A Vector of HashMaps, where each HashMap is a set field/value pairs for one record
   * @return The result of the operation.
   */
  @Override
  public Status scan(String table, String startkey, int recordcount, Set<String> fields,
                              Vector<HashMap<String, ByteIterator>> result){
    // we also don't care about reads...?
    return Status.OK;
  }

  /**
   * Update a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key, overwriting any existing values with the same field name.
   *
   * @param table The name of the table
   * @param key The record key of the record to write.
   * @param values A HashMap of field/value pairs to update in the record
   * @return The result of the operation.
   */
  @Override
  public Status update(String table, String key, Map<String, ByteIterator> values){

    Optional<TableIdentifier> tblIdentifier = getIdentifierFromTableName(table);

    if(!tblIdentifier.isPresent()){
      return Status.BAD_REQUEST;
    } else {
      return Status.OK;
    }


    // WIP
  //
  //    Transaction tx = catalog.newReplaceTableTransaction(tblIdentifier, ,false);
  //    tx.newRowDelta() for hashmap of key/values to update


  }

  /**
   * Insert a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key.
   *
   * @param table The name of the table
   * @param key The record key of the record to insert.
   * @param values A HashMap of field/value pairs to insert in the record
   * @return The result of the operation.
   */
  @Override
  public Status insert(String table, String key, Map<String, ByteIterator> values){

    Optional<TableIdentifier> tblIdentifier = getIdentifierFromTableName(table);

    if(!tblIdentifier.isPresent()){
      return Status.BAD_REQUEST;
    } else {
      return Status.OK;
    }

//    Transaction tx = catalog.newReplaceTableTransaction(tblIdentifier, ,false);
//    tx.newAppend()
  }

  /**
   * Delete a record from the database.
   *
   * @param table The name of the table
   * @param key The record key of the record to delete.
   * @return The result of the operation.
   */
  @Override
  public Status delete(String table, String key){

    Optional<TableIdentifier> tblIdentifier = getIdentifierFromTableName(table);

    if(!tblIdentifier.isPresent()){
      return Status.BAD_REQUEST;
    }

    if(catalog.dropTable(tblIdentifier.get())){
      return Status.OK;
    } else {
      return Status.ERROR;
    }

  }

}